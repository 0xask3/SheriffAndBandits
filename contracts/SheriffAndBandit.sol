// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "./ISheriffAndBandit.sol";
import "./ITrain.sol";
import "./ITraits.sol";
import "./IWEST.sol";
import "./ISeed.sol";

contract SheriffAndBandit is
    ISheriffAndBandit,
    ERC721Enumerable,
    Ownable,
    Pausable
{
    // mint price
    uint256 public MINT_PRICE = 0.003 ether;
    // max number of tokens that can be minted - 50000 in production
    uint256 public immutable MAX_TOKENS;
    // number of tokens that can be claimed for free - 20% of MAX_TOKENS
    uint256 public PAID_TOKENS;
    // number of tokens have been minted so far
    uint16 public minted;

    // mapping from tokenId to a struct containing the token's traits
    mapping(uint256 => BanditSheriff) public tokenTraits;
    mapping(uint256 => Bandit) public banditTraits;
    mapping(uint256 => Sheriff) public sheriffTraits;
    // mapping from hashed(tokenTrait) to the tokenId it's associated with
    // used to ensure there are no duplicates
    mapping(uint256 => uint256) public existingCombinations;
    // reference to the Train for choosing random Sheriff bandits
    ITrain public train;
    // reference to $WEST for burning on mint
    IWEST public west;
    // reference to Traits
    ITraits public traits;

    ISeed public randomSource;

    bool private _reentrant = false;

    modifier nonReentrant() {
        require(!_reentrant, "No reentrancy");
        _reentrant = true;
        _;
        _reentrant = false;
    }

    /**
     * instantiates contract and rarity tables
     */
    constructor(
        IWEST _west,
        ITraits _traits,
        uint256 _maxTokens
    ) ERC721("Sheriff & Bandit Game", "SHERIFF") {
        west = _west;
        traits = _traits;

        MAX_TOKENS = _maxTokens;
        PAID_TOKENS = _maxTokens / 5;
    }

    function setRandomSource(ISeed _seed) external onlyOwner {
        randomSource = _seed;
    }

    /***EXTERNAL */

    /**
     * mint a token - 90% Bandit, 10% Sheriffs
     * The first 20% are free to claim, the remaining cost $WEST
     */
    function mint(uint256 amount, bool stake)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(tx.origin == _msgSender(), "Only EOA");
        require(minted + amount <= MAX_TOKENS, "All tokens minted");
        require(amount > 0 && amount <= 30, "Invalid mint amount");

        if (minted < PAID_TOKENS) {
            require(
                minted + amount <= PAID_TOKENS,
                "All tokens on-sale already sold"
            );
            require(amount * MINT_PRICE == msg.value, "Invalid payment amount");
        } else {
            require(msg.value == 0);
        }

        uint256 totalWestCost = 0;
        uint16[] memory tokenIds = new uint16[](amount);
        address[] memory owners = new address[](amount);
        uint256 seed;
        uint256 firstMinted = minted;

        for (uint256 i = 0; i < amount; i++) {
            minted++;
            seed = random(minted);
            randomSource.update(minted ^ seed);
            generate(minted, seed);
            address recipient = selectRecipient(seed);
            totalWestCost += mintCost(minted);
            if (!stake || recipient != _msgSender()) {
                owners[i] = recipient;
            } else {
                tokenIds[i] = minted;
                owners[i] = address(train);
            }
        }

        if (totalWestCost > 0) west.burn(_msgSender(), totalWestCost);

        for (uint256 i = 0; i < owners.length; i++) {
            uint256 id = firstMinted + i + 1;
            if (!stake || owners[i] != _msgSender()) {
                _safeMint(owners[i], id);
            }
        }
        if (stake) train.addManyToTrainAndPack(_msgSender(), tokenIds);
    }

    /**
     * the first 20% are paid in BNB
     * the next 20% are 20000 $WEST
     * the next 40% are 40000 $WEST
     * the final 20% are 80000 $WEST
     * @param tokenId the ID to check the cost of to mint
     * @return the cost of the given token ID
     */
    function mintCost(uint256 tokenId) public view returns (uint256) {
        if (tokenId <= PAID_TOKENS) return 0;
        if (tokenId <= (MAX_TOKENS * 2) / 5) return 20000 ether;
        if (tokenId <= (MAX_TOKENS * 4) / 5) return 40000 ether;
        return 60000 ether;
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override nonReentrant {
        // Hardcode the Train's approval so that users don't have to waste gas approving
        if (_msgSender() != address(train))
            require(
                _isApprovedOrOwner(_msgSender(), tokenId),
                "ERC721: transfer caller is not owner nor approved"
            );
        _transfer(from, to, tokenId);
    }

    /***INTERNAL */

    /**
     * generates traits for a specific token, checking to make sure it's unique
     * @param tokenId the id of the token to generate traits for
     * @param seed a pseudorandom 256 bit number to derive traits from
     * @return t - a struct of traits for the given token ID
     */
    function generate(uint256 tokenId, uint256 seed)
        internal
        returns (
            BanditSheriff memory t,
            Sheriff memory s,
            Bandit memory b
        )
    {
        (t, s, b) = selectTraits(seed);
        if (existingCombinations[structToHash(t, s, b)] == 0) {
            tokenTraits[tokenId] = t;
            banditTraits[tokenId] = b;
            sheriffTraits[tokenId] = s;
            existingCombinations[structToHash(t, s, b)] = tokenId;
            return (t, s, b);
        }
        return generate(tokenId, random(seed));
    }

    /**
     * uses A.J. Walker's Alias algorithm for O(1) rarity table lookup
     * ensuring O(1) instead of O(n) reduces mint cost by more than 50%
     * probability & alias tables are generated off-chain beforehand
     * @param seed portion of the 256 bit seed to remove trait correlation
     * @param traitType the trait type to select a trait for
     * @return the ID of the randomly selected trait
     */
    function selectTrait(uint16 seed, uint8 traitType)
        internal
        view
        returns (uint8)
    {
        return traits.selectTrait(seed, traitType);
    }

    /**
     * the first 20% (ETH purchases) go to the minter
     * the remaining 80% have a 10% chance to be given to a random staked sheriff
     * @param seed a random value to select a recipient from
     * @return the address of the recipient (either the minter or the Sheriff bandit's owner)
     */
    function selectRecipient(uint256 seed) internal view returns (address) {
        if (minted <= PAID_TOKENS || ((seed >> 245) % 10) != 0)
            return _msgSender();
        // top 10 bits haven't been used
        address bandit = train.randomSheriffOwner(seed >> 144);
        // 144 bits reserved for trait selection
        if (bandit == address(0x0)) return _msgSender();
        return bandit;
    }

    /**
     * selects the species and all of its traits based on the seed value
     * @param seed a pseudorandom 256 bit number to derive traits from
     * @return t -  a struct of randomly selected traits
     */
    function selectTraits(uint256 seed)
        internal
        view
        returns (
            BanditSheriff memory t,
            Sheriff memory s,
            Bandit memory b
        )
    {
        t.isBandit = (seed & 0xFFFF) % 10 != 0;

        if (t.isBandit) {
            seed >>= 16;
            t.uniform = selectTrait(uint16(seed & 0xFFFF), 0);

            seed >>= 16;
            t.hair = selectTrait(uint16(seed & 0xFFFF), 1);

            seed >>= 16;
            t.eyes = selectTrait(uint16(seed & 0xFFFF), 2);

            seed >>= 16;
            t.gun = selectTrait(uint16(seed & 0xFFFF), 3);

            seed >>= 16;
            t.hat = selectTrait(uint16(seed & 0xFFFF), 4);

            seed >>= 16;
            b.accessories = selectTrait(uint16(seed & 0xFFFF), 5);

            seed >>= 16;
            b.mask = selectTrait(uint16(seed & 0xFFFF), 6);

            seed >>= 16;
            b.necklace = selectTrait(uint16(seed & 0xFFFF), 7);
        } else {
            seed >>= 16;
            t.uniform = selectTrait(uint16(seed & 0xFFFF), 8);

            seed >>= 16;
            t.hair = selectTrait(uint16(seed & 0xFFFF), 9);

            seed >>= 16;
            t.eyes = selectTrait(uint16(seed & 0xFFFF), 10);

            seed >>= 16;
            t.gun = selectTrait(uint16(seed & 0xFFFF), 11);

            seed >>= 16;
            t.hat = selectTrait(uint16(seed & 0xFFFF), 12);

            // seed >>= 16;
            // s.chain = selectTrait(uint16(seed & 0xFFFF), 13);

            seed >>= 16;
            s.mustache = selectTrait(uint16(seed & 0xFFFF), 13);

            seed >>= 16;
            s.stars = selectTrait(uint16(seed & 0xFFFF), 14);

            seed >>= 16;
            s.alphaIndex = selectTrait(uint16(seed & 0xFFFF), 15);
        }
    }

    /**
     * converts a struct to a 256 bit hash to check for uniqueness
     * @param s the struct to pack into a hash
     * @return the 256 bit hash of the struct
     */
    function structToHash(
        BanditSheriff memory t,
        Sheriff memory s,
        Bandit memory b
    ) internal pure returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        t.isBandit,
                        t.uniform,
                        t.hair,
                        t.eyes,
                        t.gun,
                        t.hat,
                        b.accessories,
                        b.mask,
                        b.necklace,
                        s.mustache,
                        s.stars,
                        s.alphaIndex
                    )
                )
            );
    }

    /**
     * generates a pseudorandom number
     * @param seed a value ensure different outcomes for different sources in the same block
     * @return a pseudorandom value
     */
    function random(uint256 seed) internal view returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        tx.origin,
                        blockhash(block.number - 1),
                        block.timestamp,
                        seed
                    )
                )
            ) ^ randomSource.seed();
    }

    /***READ */

    function getTokenTraits(uint256 tokenId)
        external
        view
        override
        returns (
            BanditSheriff memory,
            Sheriff memory,
            Bandit memory
        )
    {
        return (
            tokenTraits[tokenId],
            sheriffTraits[tokenId],
            banditTraits[tokenId]
        );
    }

    function getPaidTokens() external view override returns (uint256) {
        return PAID_TOKENS;
    }

    /***ADMIN */

    /**
     * called after deployment so that the contract can get random sheriff bandits
     * @param _train the address of the Train
     */
    function setTrain(address _train) external onlyOwner {
        train = ITrain(_train);
    }

    /**
     * allows owner to withdraw funds from minting
     */
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /**
     * updates the number of tokens for sale
     */
    function setPaidTokens(uint256 _paidTokens) external onlyOwner {
        PAID_TOKENS = _paidTokens;
    }

    /**
     * enables owner to pause / unpause minting
     */
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }

    /***RENDER */

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        require(
            _exists(tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );
        return traits.tokenURI(tokenId);
    }

    function changePrice(uint256 _price) public onlyOwner {
        MINT_PRICE = _price;
    }

    function setTraits(ITraits addr) public onlyOwner {
        traits = addr;
    }
}
