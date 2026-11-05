#!/usr/bin/env node
// Copies the data the extension compiles in into JSON assets the app bundles, so the phone and
// the extension name the same tokens, trust the same channels, pay the same treasury and link
// the same explorers. Nothing is re-derived here: every value is read from the extension's own
// modules and written out unchanged.
//
//   node scripts/sync-extension-data.mjs [path/to/zunia-extension]
//
// Requires Node 23.6+ (type stripping). Run it after the extension regenerates its tables, then
// commit assets/data/*.json together with the extension commit it came from.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const extension = resolve(process.argv[2] ?? resolve(root, "../zunia-extension"));
const out = resolve(root, "assets/data");
mkdirSync(out, { recursive: true });

const load = (rel) => import(pathToFileURL(resolve(extension, rel)).href);

const commit = execFileSync("git", ["-C", extension, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const version = JSON.parse(
  execFileSync("git", ["-C", extension, "show", "HEAD:package.json"], { encoding: "utf8" }),
).version;

const tokens = await load("lib/token-registry.generated.ts");
const channels = await load("lib/ibc-channels.generated.ts");
const fees = await load("config/fees.ts");
const interchain = await load("config/interchain.ts");
const prices = await load("config/prices.ts");

const files = {
  "token-registry.json": {
    sources: tokens.TOKEN_REGISTRY_SOURCES,
    logoPrefixes: tokens.TOKEN_LOGO_PREFIXES,
    chains: tokens.TOKEN_CHAINS,
    logos: tokens.TOKEN_LOGOS,
    groups: tokens.TOKEN_GROUPS,
    rows: tokens.TOKEN_ROWS,
    catalogLogos: tokens.CATALOG_LOGOS,
  },
  "ibc-channels.json": {
    commit: channels.IBC_CHANNELS_COMMIT,
    rows: channels.IBC_CHANNEL_ROWS,
  },
  "swap-fee.json": {
    bps: fees.SWAP_FEE_BPS,
    recipients: fees.SWAP_FEE_RECIPIENTS,
  },
  "interchain.json": {
    swapVenueChainId: interchain.SWAP_VENUE_CHAIN_ID,
    xcsContractCandidates: interchain.XCS_CONTRACT_CANDIDATES,
    swapRouterEndpoints: interchain.SWAP_ROUTER_ENDPOINTS,
    defaultSlippagePercent: interchain.DEFAULT_SLIPPAGE_PERCENT,
    slippagePresets: interchain.SLIPPAGE_PRESETS,
    highSlippagePercent: interchain.HIGH_SLIPPAGE_PERCENT,
    maxSlippagePercent: interchain.MAX_SLIPPAGE_PERCENT,
    packetTimeoutMinutes: interchain.PACKET_TIMEOUT_MINUTES,
    maxRouteHops: interchain.MAX_ROUTE_HOPS,
    quoteTtlMs: interchain.QUOTE_TTL_MS,
    moduleSupportPins: interchain.MODULE_SUPPORT_PINS,
    explorerTxUrls: interchain.EXPLORER_TX_URLS,
  },
  "prices.json": {
    exchangeSources: prices.EXCHANGE_PRICE_SOURCES,
  },
};

const manifest = { extensionVersion: version, extensionCommit: commit, files: {} };
for (const [name, body] of Object.entries(files)) {
  const text = JSON.stringify(body) + "\n";
  writeFileSync(resolve(out, name), text);
  manifest.files[name] = createHash("sha256").update(text).digest("hex");
}
writeFileSync(resolve(out, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log(`assets/data from zunia-extension ${version} @ ${commit.slice(0, 12)}`);
for (const [name, hash] of Object.entries(manifest.files)) console.log(`  ${name}  ${hash.slice(0, 16)}`);
