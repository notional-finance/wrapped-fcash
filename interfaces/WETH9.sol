// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;

interface WETH9 {
    function symbol() external view returns (string memory);

    function deposit() external payable;

    function withdraw(uint256 wad) external;

    function transfer(address dst, uint wad) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}
