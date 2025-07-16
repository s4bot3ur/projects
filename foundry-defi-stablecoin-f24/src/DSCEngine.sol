// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "../src/libraries/OracleLib.sol";
import {console} from "forge-std/Test.sol";
// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

/**
 * @title DSCEngine
 * @author s4bot3ur
 *
 * The system is desined to as minimal as possible and have the tokens maintain a 1 token= $1 peg
 * This stablecoin has properties
 * - Exogenous Collateral
 * - Dollar Pegge
 * - Algorithmic Stable
 *
 * It is simillar to DAI if DAI had no governence , no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= $backed value of all DSC
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and reedeming DSC, as well as depositing and withdrawing collateral
 * @notice This contract is VERY loosely based on the MakerDAO DSS(DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    //////////////////
    // Errors   //
    /////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCENGINE__HealthFactorNotImproved();

    //////////////////
    //Types//////////
    /////////////////

    using OracleLib for AggregatorV3Interface;

    //////////////////
    // State Variables   //
    /////////////////

    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //This means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////
    // Events      //
    /////////////////

    event CollateralDeposit(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address redeemedTo, address indexed token, uint256 indexed amount
    );
    //////////////////
    // Modifiers   //
    /////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //////////////////
    // Functions   //
    /////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*
    * @param tokenCollateralAddress: The address of the token to deposit as collateral
    * @param amountCollateral: The amount of collateral to deposit
    * @param amountDscToMint: The amount of decentralized stablecoin to mint
    * notice this function will deposit your collateral and mint DSC in one transaction
    */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /*
     * @notice follows CEI(checks,effects,interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposit(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
    * @param tokenCollateralAddress The address of the token to redeem as collateral
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of decentralized stablecoin to burn
    * This function burns DSC and redeems undelying collateral in one transaction. 
    */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //Redeem collateral already checks health factor
    }
    // in order to redeem collateral
    // 1. health factor must be over 1 After collateral pulled.
    // DRY: Don't Repeat Yourself
    // CEI: Checks, Effects, Interactions

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //
    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
    * @notice follows CEI
    * @param amountDscToMint the amount of decentralized stablecoin to mint
    * @notice they must have more collateral than value of minimum threshold
    */
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /*
    * @param collateral the erc20 collateral address to liquidate from the user
    * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC you want to burn to imporove users health factor
    * @notice You will get a liquidation bonus for taking the user funds
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
    * @notice A known bug would be if the protocol were 100% or less collateralized then,
    *  we wouldn't be able to incetive the liquidators.
    * 
    */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //need to check the health factor of the user
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        //We want to burn their DSC "debt"  (Amount of DSC they have)
        //And take their collateral
        //Bad User: $140ETH, $100 DSC
        //debtToCover=$100
        //$100 of DSC==?ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //give them 10% of bonus
        //so we are giving the liquidator $110 of WETH for $100 of DSC
        //We should implement a feature to liquidate in the event the protocol is insolvent
        //And sweep extra amounts into treasury.
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        //We need to burn the DSC
        _burnDSC(debtToCover, user, msg.sender);
        uint256 endingHealthFactor = _healthFactor(user);
        console.log(startingHealthFactor);
        console.log(endingHealthFactor);
        if (endingHealthFactor <= startingHealthFactor) {
            revert DSCENGINE__HealthFactorNotImproved();
        }
    }

    function getHealthFactor() external view returns (uint256) {
        return _healthFactor(msg.sender);
    }

    ///////////////////////////////////////
    ///Private & Internal Functions///////
    //////////////////////////////////////

    /*
    * @dev Low-level internal function, do not call unless the function calling it is checking
    * for the health factor of the user
    */

    function _burnDSC(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
    * Returns how close to liquidation a user is
    * If a user goes below 1, then they can get liquidated
    */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        view
        returns (uint256)
    {
        // total DSC minted
        // total collateral VALUE
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        //return (collateralValueInUsd / totalDscMinted);

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////////////////
    //public & External view functions////
    /////////////////////////////////////
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //price of ETH (token)
        // $/ETH ??
        // $2000/ETH for 1000$ =0.5 eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //1 ETH=$1000
        //The returned value of chainlink will be 1000*1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
        //($10e18*1e18)/($2000e8*1e10)
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(msg.sender);
    }

    function getCollateranlTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        view
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getCollateranlTokenPriceFeed(address _token) external view returns (address) {
        return s_priceFeeds[_token];
    }
}
