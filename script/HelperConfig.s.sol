// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address weth;
        address wbtc;
        address wethUSDPriceFeed;
        address wbtcUSDPriceFeed;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    uint256 public constant MOCK_WETH_BALANCE = 1000e8;
    uint256 public constant MOCK_WBTC_BALANCE = 2000e8;
    int256 public constant ETH_USD_MOCK_PRICE = 2000e8;
    int256 public constant BTC_USD_MOCK_PRICE = 80000e8;
    uint256 public constant DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public returns (NetworkConfig memory) {
        return NetworkConfig({
            weth: 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9,
            wbtc: 0x92f3B59a79bFf5dc60c0d59eA13a44D082B2bdFC,
            wethUSDPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcUSDPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.weth != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        ERC20Mock wethMock = new ERC20Mock("Wrapped Ether", "WETH", msg.sender, MOCK_WETH_BALANCE);
        ERC20Mock wbtcMock = new ERC20Mock("Wrapped Bitcoin", "WBTC", msg.sender, MOCK_WBTC_BALANCE);
        MockV3Aggregator wethUSDPriceFeedMock = new MockV3Aggregator(DECIMALS, int256(ETH_USD_MOCK_PRICE));
        MockV3Aggregator wbtcUSDPriceFeed = new MockV3Aggregator(DECIMALS, int256(BTC_USD_MOCK_PRICE));
        vm.stopBroadcast();

        return NetworkConfig({
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            wethUSDPriceFeed: address(wethUSDPriceFeedMock),
            wbtcUSDPriceFeed: address(wbtcUSDPriceFeed),
            deployerKey: DEFAULT_ANVIL_PRIVATE_KEY
        });
    }
}
