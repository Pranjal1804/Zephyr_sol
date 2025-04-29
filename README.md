```markdown


# Zephyr Protocol

Zephyr is a decentralized lending and borrowing protocol built on Solidity, enabling users to supply assets as collateral and borrow against them.

## Overview

Zephyr Protocol allows users to:
- Supply assets and earn interest
- Use supplied assets as collateral
- Borrow against collateral at dynamic interest rates
- Participate in liquidations of undercollateralized positions

## Key Components

- **ZephyrProtocol**: Core contract handling lending, borrowing, and liquidation functionality
- **ZToken**: ERC20-compatible token representing user deposits in the protocol

## Features

- Dynamic interest rate model with jump rates
- Collateralization and risk management
- Liquidation mechanism with liquidator bonus
- Reserve accumulation for protocol sustainability

## Important Notice for Deployment

Before deploying this protocol to a live network, you **MUST** make the following changes:

1. **Price Oracle Integration**: 
   - Replace the placeholder `getAssetPriceUSD` function with integration to a proper price oracle like Chainlink
   - The current implementation returns a fixed price of 1 USD for all assets

2. **Interest Rate Parameters**: 
   - Adjust interest rate parameters (baseRate, multiplier, jumpMultiplier) based on your risk model
   - Current values are examples and may not be suitable for production

3. **Risk Parameters**:
   - Adjust collateral factors for each asset based on risk profile
   - The LIQUIDATION_THRESHOLD, LIQUIDATION_BONUS, and other constants should be evaluated

4. **Security Audits**:
   - This code has not been audited and should not be deployed without a thorough security audit

## Usage

### Deployment

1. Deploy the ZephyrProtocol contract with a fee collector address
2. For each supported asset:
   - Deploy a ZToken contract
   - Call `listMarket` on ZephyrProtocol with the asset, collateral factor, and ZToken address

### User Operations

**Supply Assets**:
```solidity
// First approve the protocol to transfer tokens
IERC20(tokenAddress).approve(zephyrProtocolAddress, amount);
// Then deposit
ZephyrProtocol(zephyrProtocolAddress).deposit(tokenAddress, amount);
```

**Enable Collateral**:
```solidity
ZephyrProtocol(zephyrProtocolAddress).enableCollateral(tokenAddress);
```

**Borrow**:
```solidity
ZephyrProtocol(zephyrProtocolAddress).borrow(tokenAddress, amount);
```

**Repay**:
```solidity
// First approve the protocol to transfer tokens
IERC20(tokenAddress).approve(zephyrProtocolAddress, amount);
// Then repay
ZephyrProtocol(zephyrProtocolAddress).repay(tokenAddress, amount);
```

**Withdraw**:
```solidity
// First approve the protocol to burn zTokens
ZToken(zTokenAddress).approve(zephyrProtocolAddress, amount);
// Then withdraw
ZephyrProtocol(zephyrProtocolAddress).withdraw(tokenAddress, amount);
```

## Smart Contract Architecture

The protocol consists of the following key contracts:

1. **ZephyrProtocol.sol**: Main contract handling all protocol logic
2. **ZToken.sol**: ERC20 tokens representing deposits in the protocol

## Development & Testing

Prerequisites:
- Node.js and npm
- Hardhat or Truffle
- Solidity compiler ^0.8.10

## Security Considerations

This protocol handles user funds and includes complex financial mechanics. Before using in production:

- Conduct thorough testing on testnets
- Perform comprehensive security audits
- Implement governance mechanisms for parameter updates
- Consider timelock mechanisms for critical functions

## Disclaimer

This code is provided as-is without any warranties. Users must assume all responsibility for testing, security, and deployment.
```