//SPDX-Liscense-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    address public USER = makeAddr("s4bot3ur");
    address public LIQUIDATOR = makeAddr("t0r4n4d0");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 20 ether;
    uint256 public constant mint_Amount = (AMOUNT_COLLATERAL / 2) * 2000;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        vm.startPrank(USER);
        ERC20Mock(weth).transfer(LIQUIDATOR, 10 ether);
    }

    //////////////////////////
    //Constructor tests///////
    //////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralLiquidator() {
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralbtc() {
        vm.startPrank(USER);
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier mintDSC() {
        vm.startPrank(USER);
        dsce.mintDSC(mint_Amount);
        vm.stopPrank();
        _;
    }

    modifier mintDSCLiquidator() {
        vm.startPrank(LIQUIDATOR);
        dsce.mintDSC(mint_Amount);
        vm.stopPrank();
        _;
    }
    

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////////
    //Price Tests ////////////
    //////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }
    //////////////////////////
    //Deposit Collateral Tests/
    //////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }


    function updateWethWbtcPrice() public {
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1000e8);
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(900e8);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositCollateral {
        vm.startPrank(USER);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
        vm.stopPrank();
    }

    //////////////////////////
    ///minting DSC tests//////
    //////////////////////////

    function testRevertIfHealthFactorNotSatisfiedDuringMinting() public depositCollateral {
        vm.startPrank(USER);
        uint256 mintingAmount = (AMOUNT_COLLATERAL / 2) * 2001;
        vm.expectRevert(abi.encodeWithSignature("DSCEngine__BreakHealthFactor(uint256)", 999500249875062468));
        dsce.mintDSC(mintingAmount);
        vm.stopPrank();
    }

    function testmintDSCAndGetAccountInfo() public depositCollateral {
        vm.startPrank(USER);
        uint256 mintingAmount = (AMOUNT_COLLATERAL / 2) * 2000;
        dsce.mintDSC(mintingAmount);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(mintingAmount, totalDscMinted);
        assertEq(collateralValueInUsd, AMOUNT_COLLATERAL * 2000);
        vm.stopPrank();
    }

    //////////////////////////
    //deposit and mint tests//
    //////////////////////////

    function testRevertdepositCollateralAndMintDscIfMintingMoreThanCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(abi.encodeWithSignature("DSCEngine__BreakHealthFactor(uint256)", 999500249875062468));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, ((mint_Amount) / 2000) * 2001);
        vm.stopPrank();
    }

    function testdepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, mint_Amount);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(mint_Amount, totalDscMinted);
        assertEq(collateralValueInUsd, AMOUNT_COLLATERAL * 2000);
        vm.stopPrank();
    }

    function testRevertsIfDepsoitIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(wbtc, 0);
        vm.stopPrank();
    }

    //////////////////////////
    //redeem Collateral///////
    //////////////////////////

    function testRevertRedeemBeforeBurning() public depositCollateral mintDSC {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSignature("DSCEngine__BreakHealthFactor(uint256)", 0));
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //////////////////////////
    ///burn DSC tests/////////
    //////////////////////////

    function testburnDSC() public depositCollateral mintDSC {
        vm.startPrank(USER);
        dsc.approve(address(dsce), mint_Amount);
        dsce.burnDSC(mint_Amount);
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        vm.stopPrank();
    }

    //////////////////////////
    //burn and redeem tests///
    //////////////////////////

    function testredeemCollateralForDsc() public depositCollateral mintDSC {
        vm.startPrank(USER);
        dsc.approve(address(dsce), mint_Amount);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, mint_Amount);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
        vm.stopPrank();
    }

    ///////////////////////////
    //Deposit and balance test/
    ///////////////////////////

    function testDepositCollateralsAndFetchCollateralValue() public depositCollateral depositCollateralbtc {
        uint256 collateralvalue = dsce.getAccountCollateralValue(USER);
        assertEq(collateralvalue, 30000e18);
        updateWethWbtcPrice();
        collateralvalue = dsce.getAccountCollateralValue(USER);
        assertEq(collateralvalue, 19000e18);
    }

    ///////////////////////////
    ///Liquidate//////////////
    //////////////////////////

    function testLiquidate() public depositCollateral mintDSC depositCollateralLiquidator mintDSCLiquidator {
        vm.startPrank(LIQUIDATOR);
        console.log(MockV3Aggregator(ethUsdPriceFeed).latestAnswer());
        updateWethWbtcPrice();
        console.log(MockV3Aggregator(ethUsdPriceFeed).latestAnswer());
        dsc.approve(address(dsce), 1000e18);
        dsce.liquidate(weth, USER, 1000e18);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        console.log(totalDscMinted);
        console.log(collateralValueInUsd);

        vm.stopPrank();
    }
}
