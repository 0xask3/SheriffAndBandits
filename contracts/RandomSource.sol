// SPDX-License-Identifier: MIT LICENSE
pragma solidity ^0.8.10;
import "@openzeppelin/contracts/access/Ownable.sol";

contract Random is Ownable {
    uint256 public seed;
    address public game;

    function setGame(address _game) external onlyOwner {
        game = _game;
    }

    function update(uint256 _delay) external returns (uint256) {
        require(msg.sender == owner() || msg.sender == game, "Nope");
        seed = seed ^ _delay;
        return seed;
    }
}
