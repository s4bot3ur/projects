// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// What are our invariants?

//1.The total supply of DSC should be less than the total value of collateral

//2.Getter view functions should never revert

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {console} from "forge-std/console.sol";
import {Handler} from "./Handler.t.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address weth;
    address wbtc;
    Handler handler;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
        //targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_protocolMustHaveMoreValueThatTotalSupplyDollars() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(dsce));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, wethDeposted);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);
        console.log("Times mint called", handler.timesMintIsCalled());
        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        dsce.getLiquidationBonus();
        dsce.getPrecision();
    }
}
