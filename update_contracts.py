import json
import re

CONTRACTS_PATH = r"e:\work_space\shll\repos\shll-web\src\config\contracts.ts"
AGENT_NFA_ABI_PATH = r"e:\work_space\shll\repos\shll\agent_nfa_abi.json"
LISTING_MANAGER_ABI_PATH = r"e:\work_space\shll\repos\shll\listing_manager_abi.json"
POLICY_GUARD_ABI_PATH = r"e:\work_space\shll\repos\shll\policy_guard_abi.json"

AGENT_NFA_ADDRESS = "0xb65ca34b1526c926c75129ef934c3ba9fe6f29f6"
LISTING_MANAGER_ADDRESS = "0x71597c159007E9FF35bcF47822913cA78B182156"
POLICY_GUARD_ADDRESS = "0xf087B0e4e829109603533FA3c81BAe101e46934b"

def update_contracts():
    with open(CONTRACTS_PATH, 'r', encoding='utf-8') as f:
        content = f.read()

    # Load ABIs
    with open(AGENT_NFA_ABI_PATH, 'r', encoding='utf-8') as f:
        agent_nfa_abi = json.dumps(json.load(f), indent=2)
    
    with open(LISTING_MANAGER_ABI_PATH, 'r', encoding='utf-8') as f:
        listing_manager_abi = json.dumps(json.load(f), indent=2)

    with open(POLICY_GUARD_ABI_PATH, 'r', encoding='utf-8') as f:
        policy_guard_abi = json.dumps(json.load(f), indent=2)

    # 1. Update AgentNFA
    start_marker = "AgentNFA: {"
    start_idx = content.find(start_marker)
    if start_idx != -1:
        addr_marker = "address:"
        addr_start = content.find(addr_marker, start_idx)
        quote_start = content.find('"', addr_start)
        quote_end = content.find('"', quote_start + 1)
        content = content[:quote_start+1] + AGENT_NFA_ADDRESS + content[quote_end:]
        
        # ABI ...
        start_idx = content.find(start_marker) # Refind position
        abi_marker = "abi:"
        abi_start = content.find(abi_marker, start_idx)
        bracket_start = content.find('[', abi_start)
        count = 0
        abi_end = -1
        for i in range(bracket_start, len(content)):
            if content[i] == '[': count += 1
            elif content[i] == ']':
                count -= 1
                if count == 0:
                    abi_end = i + 1
                    break
        if abi_end != -1:
            content = content[:bracket_start] + agent_nfa_abi + content[abi_end:]

    # 2. Update ListingManager
    start_marker = "ListingManager: {"
    start_idx = content.find(start_marker)
    if start_idx != -1:
        addr_marker = "address:"
        addr_start = content.find(addr_marker, start_idx)
        quote_start = content.find('"', addr_start)
        quote_end = content.find('"', quote_start + 1)
        content = content[:quote_start+1] + LISTING_MANAGER_ADDRESS + content[quote_end:]
        
        start_idx = content.find(start_marker)
        abi_start = content.find(abi_marker, start_idx)
        bracket_start = content.find('[', abi_start)
        count = 0
        abi_end = -1
        for i in range(bracket_start, len(content)):
            if content[i] == '[': count += 1
            elif content[i] == ']':
                count -= 1
                if count == 0:
                    abi_end = i + 1
                    break
        if abi_end != -1:
            content = content[:bracket_start] + listing_manager_abi + content[abi_end:]

    # 3. Add/Update PolicyGuard
    start_marker = "PolicyGuard: {"
    start_idx = content.find(start_marker)
    
    if start_idx != -1:
        # Update existing
        addr_marker = "address:"
        addr_start = content.find(addr_marker, start_idx)
        quote_start = content.find('"', addr_start)
        quote_end = content.find('"', quote_start + 1)
        content = content[:quote_start+1] + POLICY_GUARD_ADDRESS + content[quote_end:]
    else:
        # Append new
        # Find last closing brace of CONTRACTS object
        # It ends with `};` usually at the very end of file exports.
        # But we need to play safe. 
        # Search for `ListingManager` block end.
        
        # Assumption: ListingManager is the last item before closing `};`
        # We can look for the last `},` or just inside `CONTRACTS`.
        
        # Let's find the end of ListingManager ABI which we just updated? 
        # Or search for `ListingManager: { ... }` 
        
        # Let's find index of "ListingManager: {"
        lm_idx = content.find("ListingManager: {")
        if lm_idx != -1:
             # Find matching brace for ListingManager object
            count = 0
            lm_end = -1
            for i in range(lm_idx + len("ListingManager: {"), len(content)):
                if content[i] == '{': count += 1
                elif content[i] == '}':
                    if count == 0:
                        lm_end = i + 1
                        break
                    count -= 1
            
            if lm_end != -1:
                # Insert PolicyGuard after ListingManager
                # Check if there is a comma
                policy_guard_str = f""",
  PolicyGuard: {{
    address: "{POLICY_GUARD_ADDRESS}" as Address,
    abi: {policy_guard_abi} as const,
  }},
"""
                content = content[:lm_end] + policy_guard_str + content[lm_end:]
        
    with open(CONTRACTS_PATH, 'w', encoding='utf-8') as f:
        f.write(content)
        
    print("Successfully updated contracts.ts with PolicyGuard")

if __name__ == "__main__":
    update_contracts()
