// SPDX-License-Identifier: MIT
pragma solidity ^0.6.11;


interface ITradeMining { 
    function tradeMining(address sender, address receiver, address operator, uint256 amount) external;
}