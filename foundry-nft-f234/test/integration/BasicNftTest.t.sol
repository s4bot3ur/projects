// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {BasicNft} from "../../src/BasicNft.sol";
import {DeployBasicNft} from "../../script/DeployBasicNft.s.sol";

contract BasicNftTest is Test {
    DeployBasicNft public deployer;
    BasicNft public basicNft;
    address public USER = makeAddr("user");
    string public constant PUG_URI =
        "https://ipfs.io/ipfs/QmWwFCd1JT2wXVGrBB6X1HEFHRsrFQXZaXWRC5gtVh1uw1?filename=shiba.json";

    function setUp() public {
        deployer = new DeployBasicNft();
        basicNft = deployer.run();
    }

    function testNameIsCorrect() public view {
        string memory expectedName = "Dogie";
        string memory actualName = basicNft.name();
        assertEq(
            keccak256(abi.encode(expectedName)),
            keccak256(abi.encode(actualName))
        );
    }

    function testCanMintAndHaveABalance() public {
        vm.prank(USER);
        basicNft.mintNft(PUG_URI);
        assert(basicNft.balanceOf(USER) == 1);
        assertEq(
            keccak256(abi.encodePacked(PUG_URI)),
            keccak256(abi.encodePacked(basicNft.tokenURI(0)))
        );
    }
}
