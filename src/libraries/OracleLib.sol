// SPDX Lincense-Identifier: MIT
pragma solidity ^0.8.19;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
 * @title: OracleLib
 * @author: Lucas Hope
 * @notice: This library is used to check the Chainlink Oracle for stale data.
 * If data is stale, it will revert the transaction and render the DSCEngine unusable.
 * 
 * We want the DSCEngine to freeze if prices become stale
 * If the Chainlink network explodes and you have money locked in the protocol, that sucks. Known bug
 */
library OracleLib { 
    error OracleLib__PriceIsStale();
    uint private constant TIMEOUT = 3 hours; // 3 * 60 * 60

    function stalePriceCheckLatestRoundData(AggregatorV3Interface priceFeed) public view returns (uint80, int256, uint256, uint256, uint80) {
       (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        
        uint256 secondsSinceLastUpdate = block.timestamp - updatedAt;
        if(secondsSinceLastUpdate > TIMEOUT) {
            revert OracleLib__PriceIsStale();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    
}