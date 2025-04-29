// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title Zephyr Protocol
 * @dev A decentralized lending and borrowing protocol
 */
contract ZephyrProtocol is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address;
    
    // ========== STATE VARIABLES ==========
    
    // Protocol parameters
    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80% threshold before liquidation
    uint256 public constant LIQUIDATION_BONUS = 5; // 5% bonus for liquidators
    uint256 public constant ORIGINATION_FEE = 1; // 0.1% fee on borrows
    uint256 public constant RESERVE_FACTOR = 10; // 10% of interest goes to reserves
    
    // Interest rate model parameters
    uint256 public baseRatePerYear = 2e16; // 2% base rate
    uint256 public multiplierPerYear = 8e16; // 8% multiplier
    uint256 public jumpMultiplierPerYear = 100e16; // 100% jump multiplier
    uint256 public optimal_utilization_rate = 80e16; // 80% optimal utilization
    
    // Time constants
    uint256 public constant SECONDS_PER_YEAR = 31536000;
    
    // Admin and fee collector
    address public feeCollector;
    
    struct Market {
        bool isListed;           // Whether this market is listed or not
        uint256 collateralFactor; // Percentage of the asset that can be used as collateral (scaled by 1e18)
        uint256 totalSupply;     // Total supply of the asset
        uint256 totalBorrows;    // Total borrows of the asset
        uint256 reserveAmount;   // Reserve amount of the asset
        uint256 lastUpdateTimestamp; // Last time the interest was accrued
        uint256 borrowIndex;     // Current borrow index (increases with interest)
        address zToken;          // zToken address that represents this market
    }
    
    struct UserData {
        uint256 borrowBalance;   // User's borrow balance
        uint256 borrowIndex;     // Borrow index when the user's balance was last updated
    }
    
    // Supported markets
    mapping(address => Market) public markets;
    address[] public marketList;
    
    // User data for each market
    mapping(address => mapping(address => UserData)) public userBorrows; // user -> token -> data
    mapping(address => mapping(address => bool)) public userCollaterals; // user -> token -> is collateral
    
    // Events
    event MarketListed(address token, address zToken);
    event Deposit(address user, address token, uint256 amount);
    event Withdraw(address user, address token, uint256 amount);
    event Borrow(address user, address token, uint256 amount);
    event Repay(address user, address token, uint256 amount);
    event Liquidate(address liquidator, address borrower, address repayToken, address collateralToken, uint256 repayAmount, uint256 seizedAmount);
    event CollateralEnabled(address user, address token);
    event CollateralDisabled(address user, address token);
    event NewInterestParams(uint256 baseRate, uint256 multiplier, uint256 jumpMultiplier, uint256 optimal);
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _feeCollector) {
        require(_feeCollector != address(0), "Fee collector cannot be zero address");
        feeCollector = _feeCollector;
    }
    
    // ========== MODIFIERS ==========
    
    modifier marketExists(address token) {
        require(markets[token].isListed, "Market not listed");
        _;
    }
    
    // ========== EXTERNAL FUNCTIONS ==========
    
    /**
     * @notice List a new market
     * @param token Asset to list
     * @param collateralFactorMantissa Percentage that can be borrowed against (scaled by 1e18)
     * @param zTokenAddress Address of the zToken contract that represents this asset
     */
    function listMarket(address token, uint256 collateralFactorMantissa, address zTokenAddress) external onlyOwner {
        require(!markets[token].isListed, "Market already listed");
        require(token != address(0), "Invalid token address");
        require(zTokenAddress != address(0), "Invalid zToken address");
        require(collateralFactorMantissa <= 90e16, "Collateral factor too high"); // Max 90%
        
        markets[token] = Market({
            isListed: true,
            collateralFactor: collateralFactorMantissa,
            totalSupply: 0,
            totalBorrows: 0,
            reserveAmount: 0,
            lastUpdateTimestamp: block.timestamp,
            borrowIndex: 1e18, // Start with index = 1
            zToken: zTokenAddress
        });
        
        marketList.push(token);
        
        emit MarketListed(token, zTokenAddress);
    }
    
    /**
     * @notice Update interest rate model parameters
     */
    function updateInterestRateModel(
        uint256 _baseRatePerYear,
        uint256 _multiplierPerYear,
        uint256 _jumpMultiplierPerYear,
        uint256 _optimal_utilization_rate
    ) external onlyOwner {
        baseRatePerYear = _baseRatePerYear;
        multiplierPerYear = _multiplierPerYear;
        jumpMultiplierPerYear = _jumpMultiplierPerYear;
        optimal_utilization_rate = _optimal_utilization_rate;
        
        emit NewInterestParams(
            _baseRatePerYear,
            _multiplierPerYear,
            _jumpMultiplierPerYear,
            _optimal_utilization_rate
        );
    }
    
    /**
     * @notice Accrue interest for a market
     * @param token The market to accrue interest for
     */
    function accrueInterest(address token) public marketExists(token) {
        Market storage market = markets[token];
        
        uint256 currentTimestamp = block.timestamp;
        uint256 timeElapsed = currentTimestamp.sub(market.lastUpdateTimestamp);
        
        if (timeElapsed == 0) {
            return;
        }
        
        uint256 borrowRate = getBorrowRate(token);
        uint256 interestFactor = borrowRate.mul(timeElapsed).div(SECONDS_PER_YEAR);
        uint256 interestAccumulated = market.totalBorrows.mul(interestFactor).div(1e18);
        
        uint256 reserveAmount = interestAccumulated.mul(RESERVE_FACTOR).div(100);
        market.reserveAmount = market.reserveAmount.add(reserveAmount);
        
        // Update total borrows with accumulated interest
        market.totalBorrows = market.totalBorrows.add(interestAccumulated);
        
        // Update borrow index
        market.borrowIndex = market.borrowIndex.mul(uint256(1e18).add(interestFactor)).div(1e18);
        
        // Update timestamp
        market.lastUpdateTimestamp = currentTimestamp;
    }
    
    /**
     * @notice Deposit tokens to the protocol
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function deposit(address token, uint256 amount) external nonReentrant marketExists(token) {
        require(amount > 0, "Amount must be greater than 0");
        
        // Accrue interest
        accrueInterest(token);
        
        // Transfer tokens from user to this contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        // Update market data
        Market storage market = markets[token];
        market.totalSupply = market.totalSupply.add(amount);
        
        // Mint zTokens to the user (1:1 initially)
        ERC20Mintable(market.zToken).mint(msg.sender, amount);
        
        emit Deposit(msg.sender, token, amount);
    }
    
    /**
     * @notice Withdraw tokens from the protocol
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     */
    function withdraw(address token, uint256 amount) external nonReentrant marketExists(token) {
        require(amount > 0, "Amount must be greater than 0");
        
        // Accrue interest
        accrueInterest(token);
        
        // Calculate liquidity and check if withdrawal is allowed
        (uint256 liquidity, uint256 shortfall) = getAccountLiquidity(msg.sender);
        
        // Convert amount to USD for comparison
        uint256 withdrawValueUSD = getAssetValueUSD(token, amount);
        
        // Ensure the withdrawal doesn't put the account underwater
        if (userCollaterals[msg.sender][token]) {
            require(liquidity >= withdrawValueUSD, "Withdrawal would lead to undercollateralization");
        }
        
        // Burn zTokens from user
        ERC20Burnable(markets[token].zToken).burnFrom(msg.sender, amount);
        
        // Update market data
        Market storage market = markets[token];
        market.totalSupply = market.totalSupply.sub(amount);
        
        // Transfer tokens to user
        IERC20(token).transfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, token, amount);
    }
    
    /**
     * @notice Borrow tokens from the protocol
     * @param token The token to borrow
     * @param amount The amount to borrow
     */
    function borrow(address token, uint256 amount) external nonReentrant marketExists(token) {
        require(amount > 0, "Amount must be greater than 0");
        
        // Accrue interest
        accrueInterest(token);
        
        Market storage market = markets[token];
        
        // Calculate fee
        uint256 fee = amount.mul(ORIGINATION_FEE).div(1000);
        uint256 amountWithFee = amount.add(fee);
        
        // Update user borrow data
        UserData storage userData = userBorrows[msg.sender][token];
        
        // If the user has an existing borrow, accrue interest
        if (userData.borrowBalance > 0) {
            userData.borrowBalance = userData.borrowBalance.mul(market.borrowIndex).div(userData.borrowIndex);
        }
        
        // Add new borrow amount
        userData.borrowBalance = userData.borrowBalance.add(amountWithFee);
        userData.borrowIndex = market.borrowIndex;
        
        // Update market total borrows
        market.totalBorrows = market.totalBorrows.add(amountWithFee);
        market.reserveAmount = market.reserveAmount.add(fee);
        
        // Check if borrower has sufficient collateral
        (uint256 liquidity, uint256 shortfall) = getAccountLiquidity(msg.sender);
        uint256 borrowValueUSD = getAssetValueUSD(token, amountWithFee);
        
        require(liquidity >= borrowValueUSD, "Insufficient collateral");
        
        // Transfer tokens to borrower
        IERC20(token).transfer(msg.sender, amount);
        
        emit Borrow(msg.sender, token, amount);
    }
    
    /**
     * @notice Repay a borrow
     * @param token The token to repay
     * @param amount The amount to repay (use type(uint256).max to repay full amount)
     */
    function repay(address token, uint256 amount) external nonReentrant marketExists(token) {
        // Accrue interest
        accrueInterest(token);
        
        Market storage market = markets[token];
        UserData storage userData = userBorrows[msg.sender][token];
        
        // Calculate current borrow balance with interest
        uint256 currentBorrowBalance = userData.borrowBalance.mul(market.borrowIndex).div(userData.borrowIndex);
        
        // If amount is max uint, repay the full balance
        uint256 repayAmount = (amount == type(uint256).max) ? currentBorrowBalance : amount;
        
        require(repayAmount <= currentBorrowBalance, "Repay amount exceeds debt");
        
        // Transfer tokens from user
        IERC20(token).transferFrom(msg.sender, address(this), repayAmount);
        
        // Update user borrow data
        userData.borrowBalance = currentBorrowBalance.sub(repayAmount);
        userData.borrowIndex = market.borrowIndex;
        
        // Update market data
        market.totalBorrows = market.totalBorrows.sub(repayAmount);
        
        emit Repay(msg.sender, token, repayAmount);
    }
    
    /**
     * @notice Liquidate an underwater position
     * @param borrower The address of the borrower to liquidate
     * @param repayToken The borrowed token to repay
     * @param collateralToken The collateral token to seize
     * @param repayAmount The amount of borrowed token to repay
     */
    function liquidate(
        address borrower, 
        address repayToken, 
        address collateralToken, 
        uint256 repayAmount
    ) external nonReentrant marketExists(repayToken) marketExists(collateralToken) {
        require(borrower != msg.sender, "Cannot liquidate yourself");
        require(repayAmount > 0, "Repay amount must be greater than 0");
        require(userCollaterals[borrower][collateralToken], "Token is not collateral for borrower");
        
        // Accrue interest for both markets
        accrueInterest(repayToken);
        accrueInterest(collateralToken);
        
        // Check if the borrower is underwater
        (, uint256 shortfall) = getAccountLiquidity(borrower);
        require(shortfall > 0, "Account not liquidatable");
        
        // Calculate current borrow balance
        UserData storage userData = userBorrows[borrower][repayToken];
        Market storage repayMarket = markets[repayToken];
        
        uint256 currentBorrowBalance = userData.borrowBalance.mul(repayMarket.borrowIndex).div(userData.borrowIndex);
        
        // Ensure repayment doesn't exceed allowed liquidation amount (50% of the debt)
        uint256 maxLiquidationAmount = currentBorrowBalance.mul(50).div(100);
        require(repayAmount <= maxLiquidationAmount, "Liquidation amount too high");
        
        // Transfer repay tokens from liquidator
        IERC20(repayToken).transferFrom(msg.sender, address(this), repayAmount);
        
        // Update borrower's debt
        userData.borrowBalance = currentBorrowBalance.sub(repayAmount);
        userData.borrowIndex = repayMarket.borrowIndex;
        
        // Update market data
        repayMarket.totalBorrows = repayMarket.totalBorrows.sub(repayAmount);
        
        // Calculate collateral to seize (including liquidation bonus)
        uint256 repayValueUSD = getAssetValueUSD(repayToken, repayAmount);
        uint256 bonusAmount = repayValueUSD.mul(LIQUIDATION_BONUS).div(100);
        uint256 totalSeizeValueUSD = repayValueUSD.add(bonusAmount);
        
        uint256 collateralPrice = getAssetPriceUSD(collateralToken);
        uint256 seizeAmount = totalSeizeValueUSD.mul(1e18).div(collateralPrice);
        
        // Burn seized zTokens from borrower
        ERC20Burnable(markets[collateralToken].zToken).burnFrom(borrower, seizeAmount);
        
        // Mint zTokens to liquidator
        ERC20Mintable(markets[collateralToken].zToken).mint(msg.sender, seizeAmount);
        
        emit Liquidate(
            msg.sender, 
            borrower, 
            repayToken, 
            collateralToken, 
            repayAmount, 
            seizeAmount
        );
    }
    
    /**
     * @notice Enable a token as collateral for the caller
     * @param token The token to enable as collateral
     */
    function enableCollateral(address token) external marketExists(token) {
        userCollaterals[msg.sender][token] = true;
        emit CollateralEnabled(msg.sender, token);
    }
    
    /**
     * @notice Disable a token as collateral for the caller
     * @param token The token to disable as collateral
     */
    function disableCollateral(address token) external marketExists(token) {
        // Check if disabling would make the account insolvent
        userCollaterals[msg.sender][token] = false;
        
        (uint256 liquidity, uint256 shortfall) = getAccountLiquidity(msg.sender);
        
        require(shortfall == 0, "Cannot disable collateral: account would be underwater");
        
        emit CollateralDisabled(msg.sender, token);
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    /**
     * @notice Calculate the current borrow rate for a market
     * @param token The market to calculate the rate for
     * @return The borrow rate per second, scaled by 1e18
     */
    function getBorrowRate(address token) public view marketExists(token) returns (uint256) {
        Market storage market = markets[token];
        
        if (market.totalSupply == 0) {
            return baseRatePerYear.div(SECONDS_PER_YEAR);
        }
        
        uint256 utilizationRate = market.totalBorrows.mul(1e18).div(market.totalSupply);
        
        if (utilizationRate <= optimal_utilization_rate) {
            // Linear increase from base rate to optimal rate
            uint256 normalRate = baseRatePerYear.add(
                utilizationRate.mul(multiplierPerYear).div(1e18)
            );
            return normalRate.div(SECONDS_PER_YEAR);
        } else {
            // Exponential increase after optimal utilization
            uint256 excessUtil = utilizationRate.sub(optimal_utilization_rate);
            
            uint256 jumpRate = baseRatePerYear.add(
                optimal_utilization_rate.mul(multiplierPerYear).div(1e18)
            ).add(
                excessUtil.mul(jumpMultiplierPerYear).div(1e18)
            );
            
            return jumpRate.div(SECONDS_PER_YEAR);
        }
    }
    
    /**
     * @notice Calculate the supply rate for a market
     * @param token The market token
     * @return The supply rate per second, scaled by 1e18
     */
    function getSupplyRate(address token) public view marketExists(token) returns (uint256) {
        Market storage market = markets[token];
        
        if (market.totalSupply == 0) {
            return 0;
        }
        
        uint256 utilizationRate = market.totalBorrows.mul(1e18).div(market.totalSupply);
        uint256 borrowRate = getBorrowRate(token);
        
        // Supply rate = borrow rate * utilization rate * (1 - reserve factor)
        return borrowRate.mul(utilizationRate).div(1e18).mul(uint256(100).sub(RESERVE_FACTOR)).div(100);
    }
    
    /**
     * @notice Get the current account liquidity and shortfall
     * @param account The account to calculate liquidity for
     * @return liquidity The excess collateral value in USD (18 decimals)
     * @return shortfall The amount the account is underwater in USD (18 decimals)
     */
    function getAccountLiquidity(address account) public view returns (uint256 liquidity, uint256 shortfall) {
        uint256 totalCollateralValueUSD = 0;
        uint256 totalBorrowValueUSD = 0;
        
        // Calculate total collateral value
        for (uint i = 0; i < marketList.length; i++) {
            address token = marketList[i];
            
            if (userCollaterals[account][token]) {
                Market storage market = markets[token];
                uint256 zTokenBalance = IERC20(market.zToken).balanceOf(account);
                
                if (zTokenBalance > 0) {
                    uint256 collateralValueUSD = getAssetValueUSD(token, zTokenBalance);
                    uint256 discountedValue = collateralValueUSD.mul(market.collateralFactor).div(1e18);
                    totalCollateralValueUSD = totalCollateralValueUSD.add(discountedValue);
                }
            }
        }
        
        // Calculate total borrow value
        for (uint i = 0; i < marketList.length; i++) {
            address token = marketList[i];
            UserData storage userData = userBorrows[account][token];
            
            if (userData.borrowBalance > 0) {
                Market storage market = markets[token];
                
                uint256 currentBorrowBalance = userData.borrowBalance.mul(market.borrowIndex).div(userData.borrowIndex);
                uint256 borrowValueUSD = getAssetValueUSD(token, currentBorrowBalance);
                
                totalBorrowValueUSD = totalBorrowValueUSD.add(borrowValueUSD);
            }
        }
        
        // Calculate liquidity or shortfall
        if (totalCollateralValueUSD >= totalBorrowValueUSD) {
            return (totalCollateralValueUSD.sub(totalBorrowValueUSD), 0);
        } else {
            return (0, totalBorrowValueUSD.sub(totalCollateralValueUSD));
        }
    }
    
    /**
     * @notice Get USD value of an asset amount (uses a price oracle)
     * @param token The asset token
     * @param amount The amount of the asset
     * @return The USD value (18 decimals)
     */
    function getAssetValueUSD(address token, uint256 amount) public view returns (uint256) {
        uint256 price = getAssetPriceUSD(token);
        uint8 decimals = IERC20Metadata(token).decimals();
        
        return amount.mul(price).div(10**uint256(decimals));
    }
    
    /**
     * @notice Get the USD price of an asset (placeholder for oracle integration)
     * @param token The asset token
     * @return The USD price per whole token (18 decimals)
     */
    function getAssetPriceUSD(address token) public view returns (uint256) {
        // Placeholder - in a real implementation, this would call a price oracle
        // For simplicity, we assume a fixed price of $1 for all assets
        return 1e18;
    }
    
    /**
     * @notice Get market data for a token
     * @param token The token to get market data for
     */
    function getMarketData(address token) external view returns (
        bool isListed,
        uint256 collateralFactor,
        uint256 totalSupply,
        uint256 totalBorrows,
        uint256 reserveAmount,
        uint256 supplyRate,
        uint256 borrowRate
    ) {
        Market storage market = markets[token];
        
        return (
            market.isListed,
            market.collateralFactor,
            market.totalSupply,
            market.totalBorrows,
            market.reserveAmount,
            getSupplyRate(token),
            getBorrowRate(token)
        );
    }
    
    /**
     * @notice Get user data for a market
     * @param user The user
     * @param token The market token
     */
    function getUserData(address user, address token) external view returns (
        uint256 borrowBalance,
        bool isCollateral
    ) {
        UserData storage userData = userBorrows[user][token];
        Market storage market = markets[token];
        
        uint256 currentBorrowBalance = 0;
        if (userData.borrowBalance > 0) {
            currentBorrowBalance = userData.borrowBalance.mul(market.borrowIndex).div(userData.borrowIndex);
        }
        
        return (
            currentBorrowBalance,
            userCollaterals[user][token]
        );
    }
    
    /**
     * @notice Update the fee collector address
     * @param newFeeCollector The new fee collector address
     */
    function updateFeeCollector(address newFeeCollector) external onlyOwner {
        require(newFeeCollector != address(0), "Fee collector cannot be zero address");
        feeCollector = newFeeCollector;
    }
    
    /**
     * @notice Withdraw accumulated reserves from a market
     * @param token The market token
     * @param amount The amount to withdraw (use type(uint256).max for all)
     */
    function withdrawReserves(address token, uint256 amount) external onlyOwner marketExists(token) {
        Market storage market = markets[token];
        
        uint256 withdrawAmount = (amount == type(uint256).max) ? market.reserveAmount : amount;
        require(withdrawAmount <= market.reserveAmount, "Amount exceeds reserves");
        
        market.reserveAmount = market.reserveAmount.sub(withdrawAmount);
        IERC20(token).transfer(feeCollector, withdrawAmount);
    }
}

/**
 * @title ERC20Mintable
 * @dev Simple interface for ERC20 tokens that can be minted
 */
interface ERC20Mintable {
    function mint(address to, uint256 amount) external;
}

/**
 * @title ZToken
 * @dev Token that represents deposits in Zephyr protocol
 */
contract ZToken is ERC20Burnable {
    address public zephyrProtocol;
    address public underlyingAsset;
    
    constructor(
        string memory name,
        string memory symbol,
        address _underlyingAsset,
        address _zephyrProtocol
    ) ERC20(name, symbol) {
        underlyingAsset = _underlyingAsset;
        zephyrProtocol = _zephyrProtocol;
    }
    
    modifier onlyProtocol() {
        require(msg.sender == zephyrProtocol, "Only protocol can call this");
        _;
    }
    
    /**
     * @notice Mint new tokens
     * @param to The address to mint to
     * @param amount The amount to mint
     */
    function mint(address to, uint256 amount) external onlyProtocol {
        _mint(to, amount);
    }
    
    /**
     * @notice Return the number of decimals (should match underlying asset)
     */
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(underlyingAsset).decimals();
    }
}