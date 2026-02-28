import { createWalletClient, createPublicClient, http, encodeFunctionData } from 'viem';
import { bsc } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

// Read private key from env
const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) {
    console.error('Set PRIVATE_KEY env var');
    process.exit(1);
}

const AGENT_NFA = '0xe98dcdbf370d7b52c9a2b88f79bef514a5375a2b';
const POLICY_GUARD = '0x25d17ea0e3bcb8ca08a2bfe917e817afc05dbbb3';

const abi = [
    {
        name: 'updateAgentMetadata',
        type: 'function',
        stateMutability: 'nonpayable',
        inputs: [
            { name: 'tokenId', type: 'uint256' },
            {
                name: 'metadata', type: 'tuple',
                components: [
                    { name: 'persona', type: 'string' },
                    { name: 'experience', type: 'string' },
                    { name: 'voiceHash', type: 'string' },
                    { name: 'animationURI', type: 'string' },
                    { name: 'vaultURI', type: 'string' },
                    { name: 'vaultHash', type: 'bytes32' },
                ]
            }
        ],
        outputs: []
    },
    {
        name: 'setLogicAddress',
        type: 'function',
        stateMutability: 'nonpayable',
        inputs: [
            { name: 'tokenId', type: 'uint256' },
            { name: 'newLogic', type: 'address' },
        ],
        outputs: []
    }
];

const account = privateKeyToAccount(PRIVATE_KEY);
const client = createWalletClient({ account, chain: bsc, transport: http('https://bsc-rpc.publicnode.com') });
const publicClient = createPublicClient({ chain: bsc, transport: http('https://bsc-rpc.publicnode.com') });

const persona = JSON.stringify({
    name: 'SHLL Agent',
    description: 'AI Agent marketplace with contract-level safety. Every agent is protected by PolicyGuard: spending limits, cooldown, receiver guard, DEX whitelist, and DeFi function filtering. Non-custodial - your keys, your assets.'
});

async function main() {
    console.log('1. Updating metadata for Token #0...');
    const tx1 = await client.writeContract({
        address: AGENT_NFA,
        abi,
        functionName: 'updateAgentMetadata',
        args: [0n, {
            persona,
            experience: 'Template',
            voiceHash: '',
            animationURI: 'https://api.shll.run/logo-highres.png',
            vaultURI: 'https://shll.xyz',
            vaultHash: '0x0000000000000000000000000000000000000000000000000000000000000000',
        }],
        gasPrice: 3000000000n,
    });
    console.log('   tx:', tx1);
    await publicClient.waitForTransactionReceipt({ hash: tx1 });
    console.log('   confirmed!');

    console.log('2. Setting Logic Address to PolicyGuardV4...');
    const tx2 = await client.writeContract({
        address: AGENT_NFA,
        abi,
        functionName: 'setLogicAddress',
        args: [0n, POLICY_GUARD],
        gasPrice: 3000000000n,
    });
    console.log('   tx:', tx2);
    await publicClient.waitForTransactionReceipt({ hash: tx2 });
    console.log('   confirmed!');

    console.log('Done! Check https://nfascan.net/agent/');
}

main().catch(e => { console.error(e); process.exit(1); });
