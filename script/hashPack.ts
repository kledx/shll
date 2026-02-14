#!/usr/bin/env node
/**
 * Capability Pack Hash Generator
 *
 * Generates a SHA256 hash of a capability pack manifest for vaultHash verification.
 *
 * Usage:
 *   node script/hashPack.ts <path-to-manifest.json>
 *   node script/hashPack.ts packs/hotpump_watchlist/manifest.json
 *
 * Output:
 *   - Canonical JSON (sorted keys)
 *   - SHA256 hash (hex)
 *   - Solidity bytes32 format
 */

import { readFileSync } from 'fs';
import { createHash } from 'crypto';

/**
 * Canonicalize JSON by sorting keys recursively
 * This ensures consistent hashing regardless of key order
 */
function canonicalizeJSON(obj: any): string {
  if (obj === null) return 'null';
  if (typeof obj !== 'object') return JSON.stringify(obj);
  if (Array.isArray(obj)) {
    return '[' + obj.map(canonicalizeJSON).join(',') + ']';
  }

  const sortedKeys = Object.keys(obj).sort();
  const pairs = sortedKeys.map(key => {
    return JSON.stringify(key) + ':' + canonicalizeJSON(obj[key]);
  });

  return '{' + pairs.join(',') + '}';
}

/**
 * Generate SHA256 hash of canonicalized JSON
 */
function hashPack(manifest: any): {
  canonical: string;
  hash: string;
  bytes32: string;
} {
  const canonical = canonicalizeJSON(manifest);
  const hash = createHash('sha256').update(canonical).digest('hex');
  const bytes32 = '0x' + hash;

  return { canonical, hash, bytes32 };
}

/**
 * Main execution
 */
function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    console.error('Usage: node hashPack.ts <path-to-manifest.json>');
    console.error('Example: node hashPack.ts packs/hotpump_watchlist/manifest.json');
    process.exit(1);
  }

  const manifestPath = args[0];

  try {
    // Read manifest file
    const manifestContent = readFileSync(manifestPath, 'utf-8');
    const manifest = JSON.parse(manifestContent);

    // Generate hash
    const result = hashPack(manifest);

    // Output results
    console.log('═══════════════════════════════════════════════════════');
    console.log('Capability Pack Hash Generator');
    console.log('═══════════════════════════════════════════════════════\n');

    console.log('Input File:', manifestPath);
    console.log('Pack Name:', manifest.name || 'N/A');
    console.log('Pack Version:', manifest.version || 'N/A');
    console.log('\n--- Canonical JSON (sorted keys) ---');
    console.log(result.canonical.substring(0, 200) + '...\n');

    console.log('--- Hash Results ---');
    console.log('SHA256 (hex):', result.hash);
    console.log('Solidity bytes32:', result.bytes32);

    console.log('\n--- Usage in Solidity ---');
    console.log('IBAP578.AgentMetadata memory metadata = IBAP578.AgentMetadata({');
    console.log('    persona: "...",');
    console.log('    experience: "...",');
    console.log('    voiceHash: "...",');
    console.log('    animationURI: "...",');
    console.log(`    vaultURI: "https://shll.run/packs/${manifest.id || 'pack'}.json",`);
    console.log(`    vaultHash: ${result.bytes32}`);
    console.log('});');

    console.log('\n✅ Hash generated successfully!');
    console.log('═══════════════════════════════════════════════════════\n');

  } catch (error: any) {
    console.error('❌ Error:', error.message);
    process.exit(1);
  }
}

// Run if called directly
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export { canonicalizeJSON, hashPack };
