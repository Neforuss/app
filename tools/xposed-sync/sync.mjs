#!/usr/bin/env node
// Regenerates NeoFreeBird's copy of X-Posed's country data from X-Posed's own
// source (https://github.com/xaitax/x-account-location-device).
//
//   node tools/xposed-sync/sync.mjs <path-to-x-posed-checkout> [--check]
//
// Writes:
//   layout/Library/Application Support/BHT/BHTwitter.bundle/xposed_sync.json
//       query ID, canonical country list, flags, lookup table, regions.
//   tests/fixtures/xposed_vectors.json
//       inputs and the answers X-Posed's own canonicalCountry() and
//       matchingBlockedRegions() give for them. tests/CustomLogicTests.m
//       requires the Objective-C port to give the same answers.
//
// --check exits 1 when either file would change (used by CI to flag drift)
// instead of writing.

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..', '..');
const [, , xposedArg, ...flags] = process.argv;
if (!xposedArg) {
    console.error('usage: node tools/xposed-sync/sync.mjs <x-posed checkout> [--check]');
    process.exit(2);
}
const checkOnly = flags.includes('--check');
const xposed = resolve(xposedArg);
const shared = join(xposed, 'extension', 'src', 'shared');

const constants = await import(pathToFileURL(join(shared, 'constants.js')).href);
const geography = await import(pathToFileURL(join(shared, 'region-geography.js')).href);
const membership = await import(pathToFileURL(join(shared, 'region-membership.js')).href);

const { API_CONFIG, COUNTRY_FLAGS, COUNTRY_ALIASES, COUNTRY_LIST, REGION_DATA, canonicalCountry } = constants;
const { REGION_GEOGRAPHY_GROUPS } = geography;
const { matchingBlockedRegions } = membership;

// Same normalisation as X-Posed's private countryLookupKey().
const lookupKey = name => name.normalize('NFKD').replace(/\p{M}/gu, '').replace(/[‘’ʼ]/g, "'");

const lookup = {};
for (const name of Object.keys(COUNTRY_FLAGS)) lookup[lookupKey(name)] = name;
for (const [alias, canonical] of Object.entries(COUNTRY_ALIASES)) lookup[lookupKey(alias)] = canonical;

// The table must reproduce canonicalCountry() for every name it covers.
for (const [key, value] of Object.entries(lookup)) {
    const expected = canonicalCountry(key);
    if (expected !== value) throw new Error(`lookup drift: ${key} -> ${value}, X-Posed says ${expected}`);
}

const regions = REGION_DATA.map(region => ({
    key: region.key,
    name: region.name,
    flag: region.flag,
    members: [...(REGION_GEOGRAPHY_GROUPS[region.key] || [])].sort(),
}));

let commit = 'unknown';
try {
    commit = execFileSync('git', ['-C', xposed, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
} catch { /* not a git checkout */ }
let version = 'unknown';
try {
    version = JSON.parse(readFileSync(join(xposed, 'extension', 'package.json'), 'utf8')).version;
} catch { /* no package.json */ }

const data = {
    generated_by: 'tools/xposed-sync/sync.mjs',
    xposed_commit: commit,
    xposed_version: version,
    query_id: API_CONFIG.QUERY_ID,
    countries: COUNTRY_LIST,
    flags: Object.fromEntries(Object.entries(COUNTRY_FLAGS).filter(([name]) => COUNTRY_LIST.includes(name))),
    lookup,
    regions,
};

// ---- Parity vectors -------------------------------------------------------
const canonicalInputs = new Set([
    '', '   ', 'Atlantis', 'Europe', 'EUROPE', 'european union', 'South Asia',
    '  united   states ', 'UNITED STATES', 'Côte d’Ivoire', "Cote d'Ivoire", 'Côte dʼIvoire',
    'Cabo Verde', 'DR Congo', 'Congo-Kinshasa', 'Swaziland', 'Réunion', 'Reunion',
]);
for (const name of Object.keys(COUNTRY_FLAGS).slice(0, 400)) {
    canonicalInputs.add(name);
    canonicalInputs.add(name.toUpperCase());
}
for (const alias of Object.keys(COUNTRY_ALIASES)) canonicalInputs.add(alias);
const canonical = [...canonicalInputs].map(input => ({ input, expected: canonicalCountry(input) }));

// Region selections in both of X-Posed's modes, as the iOS picker offers
// them: label only (X-Posed's default: no record entry, so only accounts
// X labels with the region itself match) and with every member country
// opted in. `included` lists the regions whose members are opted in.
const blocking = [];
const probeLocations = ['United States', 'Germany', 'France', 'Ukraine', 'India', 'Brazil', 'Japan',
    'Nigeria', 'Australia', 'Europe', 'European Union', 'South Asia', 'Atlantis', '',
    'Côte d’Ivoire', 'Russia', 'Taiwan', 'Mexico', 'Jamaica', 'Egypt'];
for (const region of regions) {
    const blocked = new Set([region.key]);
    for (const includeMembers of [false, true]) {
        const record = includeMembers ? { [region.key]: region.members } : {};
        for (const location of probeLocations) {
            blocking.push({
                location,
                blocked: [region.key],
                included: includeMembers ? [region.key] : [],
                expected: matchingBlockedRegions(location, blocked, record).length > 0,
            });
        }
    }
}
for (const country of ['united states', 'germany', 'india', 'côte d\'ivoire']) {
    for (const location of probeLocations) {
        blocking.push({
            location,
            blocked: [country],
            included: [],
            expected: matchingBlockedRegions(location, new Set([country]), {}).length > 0,
        });
    }
}
const vectors = { generated_by: data.generated_by, xposed_commit: commit, canonical, blocking };

// ---- Write / check --------------------------------------------------------
const outputs = [
    [join(repoRoot, 'layout', 'Library', 'Application Support', 'BHT', 'BHTwitter.bundle', 'xposed_sync.json'), data],
    [join(repoRoot, 'tests', 'fixtures', 'xposed_vectors.json'), vectors],
];

// The commit hash changes on every upstream push, data or not; compare
// content without it so --check only fails on real data drift.
const comparable = obj => JSON.stringify({ ...obj, xposed_commit: undefined, xposed_version: undefined });

let drift = false;
for (const [path, value] of outputs) {
    const text = JSON.stringify(value, null, 2) + '\n';
    const current = existsSync(path) ? readFileSync(path, 'utf8') : '';
    const same = current && comparable(JSON.parse(current)) === comparable(value);
    if (!same) drift = true;
    if (checkOnly) {
        if (!same) console.log(`DRIFT ${path}`);
        continue;
    }
    // Leave files untouched when only the commit/version stamp moved, so the
    // weekly job opens a PR only for real data changes.
    if (same) {
        console.log(`unchanged ${path}`);
        continue;
    }
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
    console.log(`updated ${path}`);
}
console.log(`X-Posed ${version} @ ${commit.slice(0, 7)}: query ${data.query_id}, ` +
    `${data.countries.length} countries, ${regions.length} regions, ` +
    `${canonical.length} canonical vectors, ${blocking.length} blocking vectors`);
if (checkOnly && drift) process.exit(1);
