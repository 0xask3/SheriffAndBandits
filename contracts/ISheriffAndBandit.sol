// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

interface ISheriffAndBandit {

    struct Bandit {
        uint8 handcuff;
        uint8 mask;
        uint8 necklace;
    }

    struct Sheriff {
        //uint8 chain;
        uint8 mustache;
        uint8 stars;
        uint8 alphaIndex;
    }

    // struct to store each token's traits
    struct BanditSheriff {
        bool isBandit;
        uint8 uniform;
        uint8 hair;
        uint8 eyes;
        uint8 gun;
        uint8 hat;
    }

    function getPaidTokens() external view returns (uint256);
    function getTokenTraits(uint256 tokenId) external view returns (BanditSheriff memory, Sheriff memory, Bandit memory);
}