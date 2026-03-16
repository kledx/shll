# MemeHunter Free NFA - Step-by-step deployment via cast send
# Run from: E:\work_space\shll\repos\shll
# Prerequisites: .env loaded, --account deployer configured

$RPC = "https://bsc-dataseed4.binance.org"
$GAS_PRICE = "1000000000"  # 1 gwei
$ACCOUNT = "deployer"

# Contract addresses (from .env / RESOURCE-MAP.yml)
$NFA = "0x71cE46099E4b2a2434111C009A7E9CFd69747c8E"
$PROTOCOL_REGISTRY = "0x1A5EA54a3beaf4fba75f73581cf6A945746E6DF1"
$LISTING_MANAGER_V2 = "0xa31348293ba3ef9b40daede742c82268f57e4ee3"
$SPENDING_LIMIT_V2 = "0x28efC8D513D44252EC26f710764ADe22b2569115"
$COOLDOWN = "0x0E0B2006DE4d68543C4069249a075C215510efDB"
$DEFI_GUARD_V2 = "0xD1b6a97400Bc62ed6000714E9810F36Fc1a251f1"
$RECEIVER_GUARD = "0x7A9618ec6c2e9D93712326a7797A829895c0AfF6"
$DEPLOYER = "0x51eD50c9e29481dB812d004EC4322CCdFa9a2868"

# Template key = keccak256("meme_hunter_free")
$TEMPLATE_KEY = "0xe7015571110c7e7bb9a34c901e5ff52fae8edfb69386bbd740845b8c5151a8c9"

Write-Host "=== MemeHunter Free NFA Deployment ===" -ForegroundColor Green
Write-Host ""

# Step 1: Get next token ID
Write-Host "[Step 0] Querying nextTokenId..." -ForegroundColor Yellow
$nextId = cast call $NFA "nextTokenId()(uint256)" --rpc-url $RPC
Write-Host "Next Token ID: $nextId"

# Step 1: Mint Agent
Write-Host ""
Write-Host "[Step 1] Minting MemeHunter Agent..." -ForegroundColor Yellow
cast send $NFA "mintAgent(address,bytes32,bytes32,string,(string,string,string,string,string,bytes32))" `
    $DEPLOYER `
    "0x0000000000000000000000000000000000000000000000000000000000000001" `
    $(cast keccak "meme_hunter") `
    "https://api.shll.run/api/metadata/$nextId" `
    '("{\"name\":\"Meme Hunter\",\"description\":\"Meme token trading agent\"}","Production","","","","0x0000000000000000000000000000000000000000000000000000000000000000")' `
    --account $ACCOUNT --rpc-url $RPC --gas-price $GAS_PRICE --gas-limit 5000000
Write-Host "Step 1 done. Token ID should be: $nextId"

# Step 2: Register Template
Write-Host ""
Write-Host "[Step 2] Registering as template..." -ForegroundColor Yellow
cast send $NFA "registerTemplate(uint256,bytes32)" `
    $nextId `
    $TEMPLATE_KEY `
    --account $ACCOUNT --rpc-url $RPC --gas-price $GAS_PRICE --gas-limit 300000
Write-Host "Step 2 done."

# Step 3a-d: Bind 4 policies via ProtocolRegistry.guardCall
Write-Host ""
Write-Host "[Step 3] Binding 4 policies via guardCall..." -ForegroundColor Yellow

# PolicyGuardV4.addTemplatePolicy selector = 0x8e7cb6e1
$ADD_POLICY_SIG = "addTemplatePolicy(bytes32,address)"

# 3a: SpendingLimitV2
$calldata_3a = cast calldata $ADD_POLICY_SIG $TEMPLATE_KEY $SPENDING_LIMIT_V2
cast send $PROTOCOL_REGISTRY "guardCall(bytes)(bytes)" $calldata_3a `
    --account $ACCOUNT --rpc-url $RPC --gas-price $GAS_PRICE --gas-limit 300000
Write-Host "  SpendingLimitV2 bound"

# 3b: Cooldown
$calldata_3b = cast calldata $ADD_POLICY_SIG $TEMPLATE_KEY $COOLDOWN
cast send $PROTOCOL_REGISTRY "guardCall(bytes)(bytes)" $calldata_3b `
    --account $ACCOUNT --rpc-url $RPC --gas-price $GAS_PRICE --gas-limit 300000
Write-Host "  Cooldown bound"

# 3c: DeFiGuardV2
$calldata_3c = cast calldata $ADD_POLICY_SIG $TEMPLATE_KEY $DEFI_GUARD_V2
cast send $PROTOCOL_REGISTRY "guardCall(bytes)(bytes)" $calldata_3c `
    --account $ACCOUNT --rpc-url $RPC --gas-price $GAS_PRICE --gas-limit 300000
Write-Host "  DeFiGuardV2 bound"

# 3d: ReceiverGuard
$calldata_3d = cast calldata $ADD_POLICY_SIG $TEMPLATE_KEY $RECEIVER_GUARD
cast send $PROTOCOL_REGISTRY "guardCall(bytes)(bytes)" $calldata_3d `
    --account $ACCOUNT --rpc-url $RPC --gas-price $GAS_PRICE --gas-limit 300000
Write-Host "  ReceiverGuard bound"

# Step 4: Spending Ceiling via emergencyCall
Write-Host ""
Write-Host "[Step 4] Setting spending ceiling..." -ForegroundColor Yellow

$calldata_4a = cast calldata "setTemplateCeiling(bytes32,uint256,uint256,uint256)" $TEMPLATE_KEY "1000000000000000000" "0" "3000"
cast send $PROTOCOL_REGISTRY "emergencyCall(address,bytes)(bytes)" $SPENDING_LIMIT_V2 $calldata_4a `
    --account $ACCOUNT --rpc-url $RPC --gas-price $GAS_PRICE --gas-limit 300000
Write-Host "  Ceiling set: 1 BNB/tx, 30% slippage"

$calldata_4b = cast calldata "setTemplateApproveCeiling(bytes32,uint256)" $TEMPLATE_KEY "100000000000000000000"
cast send $PROTOCOL_REGISTRY "emergencyCall(address,bytes)(bytes)" $SPENDING_LIMIT_V2 $calldata_4b `
    --account $ACCOUNT --rpc-url $RPC --gas-price $GAS_PRICE --gas-limit 300000
Write-Host "  Approve ceiling set: 100 BNB"

# Step 5: Create free listing
Write-Host ""
Write-Host "[Step 5] Creating free listing..." -ForegroundColor Yellow
cast send $LISTING_MANAGER_V2 "createTemplateListing(address,uint256,uint96,uint32)" `
    $NFA $nextId "0" "7" `
    --account $ACCOUNT --rpc-url $RPC --gas-price $GAS_PRICE --gas-limit 500000
Write-Host "Step 5 done."

Write-Host ""
Write-Host "=== ALL DONE ===" -ForegroundColor Green
Write-Host "Token ID: $nextId"
$vault = cast call $NFA "accountOf(uint256)(address)" $nextId --rpc-url $RPC
Write-Host "Vault: $vault"
