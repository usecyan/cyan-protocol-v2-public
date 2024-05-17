// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

contract Greeter {
    string hello = "Sain baina uu?";

    function greet() external view returns (string memory) {
        return hello;
    }

    function updateGreetings(string calldata _hello) external {
        hello = _hello;
    }
}
