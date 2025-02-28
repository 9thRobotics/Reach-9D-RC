// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract ReachToken is ERC20, Ownable, ReentrancyGuard {
    uint256 public constant TOTAL_SUPPLY = 18_000_000_000 * 10**18;
    uint256 public floorPrice = 27 * 1e18; // $27 per token
    uint256 public buybackReserve;
    uint256 public transactionFee = 50; // 0.5% fee
    uint256 public buybackAllocation = 50; // 50% of fees go to buyback pool
    uint256 public stakingAllocation = 30; // 30% of buybacks go to stakers
    uint256 public unlockPeriod = 7 days;
    address public buybackWallet;

    AggregatorV3Interface internal priceFeed;

    mapping(address => uint256) public stakingBalance;
    mapping(address => uint256) public lastStakeTime;
    mapping(address => uint256) public lockedTokens;
    mapping(address => uint256) public unlockTimestamp;

    struct Proposal {
        uint256 newFloorPrice;
        uint256 voteCount;
        bool executed;
        address creator;
    }

    Proposal[] public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event TokensBought(address indexed buyer, uint256 ethSpent, uint256 tokensReceived);
    event BuybackExecuted(uint256 amount, uint256 price);
    event TokensStaked(address indexed user, uint256 amount, uint256 lockTime);
    event TokensUnstaked(address indexed user, uint256 amount);
    event ProposalCreated(uint256 proposalId, uint256 newFloorPrice);
    event VoteCast(address voter, uint256 proposalId);

    /** 🔥 Constructor with Proper Validation */
    constructor(address _priceFeed, address _buybackWallet) 
        ERC20("Reach Token", "9D-RC") 
        Ownable(msg.sender) 
        ReentrancyGuard()
    {
        require(_priceFeed != address(0), "Invalid price feed address");
        require(_buybackWallet != address(0), "Invalid buyback wallet");

        _mint(msg.sender, TOTAL_SUPPLY);
        priceFeed = AggregatorV3Interface(_priceFeed);
        buybackWallet = _buybackWallet;
    }

    /** 🔥 Get the latest Chainlink price */
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , ,) = priceFeed.latestRoundData();
        return uint256(price) * 1e10;
    }

    /** 🔥 Buy function */
    function buyTokens() public payable nonReentrant {
        require(msg.value > 0, "Must send ETH to buy tokens");

        uint256 currentPrice = getLatestPrice();
        if (currentPrice < floorPrice) {
            currentPrice = floorPrice;
        }

        uint256 tokensToBuy = (msg.value * 1e18) / currentPrice;
        require(tokensToBuy > 0, "Not enough ETH sent");

        _transfer(owner(), msg.sender, tokensToBuy);

        uint256 buybackContribution = (msg.value * buybackAllocation) / 100;
        buybackReserve += buybackContribution;

        emit TokensBought(msg.sender, msg.value, tokensToBuy);
    }

    /** 🔥 Adjust supply (lock/unlock tokens if price changes) */
    function adjustSupply() public onlyOwner {
        uint256 currentPrice = getLatestPrice();

        if (currentPrice < floorPrice) {
            uint256 amountToLock = totalSupply() * 10 / 100;
            _burn(owner(), amountToLock);
        } else if (currentPrice > floorPrice * 2) {
            uint256 amountToRelease = totalSupply() * 5 / 100;
            _mint(owner(), amountToRelease);
        }
    }

    /** 🔥 Buyback mechanism with Proper Validation */
    function executeBuyback() public onlyOwner nonReentrant {
        uint256 currentPrice = getLatestPrice();
        require(currentPrice < floorPrice, "Price is above the floor");
        require(buybackReserve > 0, "No funds available for buyback");

        uint256 amountToBuy = buybackReserve / currentPrice;
        buybackReserve -= amountToBuy * currentPrice;
        _mint(address(this), amountToBuy);

        emit BuybackExecuted(amountToBuy, currentPrice);
    }

    /** 🔥 Deposit ETH to buyback pool */
    function depositBuybackFunds() external payable onlyOwner {
        require(msg.value > 0, "Deposit must be greater than 0");
        buybackReserve += msg.value;
    }

    /** 🔥 Staking with lock-up */
    function stakeTokens(uint256 _amount, uint256 _lockPeriod) external nonReentrant {
        require(balanceOf(msg.sender) >= _amount, "Not enough tokens");
        require(_lockPeriod == 3 || _lockPeriod == 6 || _lockPeriod == 12, "Invalid staking period");

        _transfer(msg.sender, address(this), _amount);
        stakingBalance[msg.sender] += _amount;
        lastStakeTime[msg.sender] = block.timestamp + (_lockPeriod * 30 days);

        emit TokensStaked(msg.sender, _amount, _lockPeriod);
    }

    function unstakeTokens() external nonReentrant {
        require(stakingBalance[msg.sender] > 0, "No staked tokens");
        require(block.timestamp >= lastStakeTime[msg.sender], "Tokens still locked");

        uint256 amount = stakingBalance[msg.sender];
        stakingBalance[msg.sender] = 0;
        _transfer(address(this), msg.sender, amount);

        emit TokensUnstaked(msg.sender, amount);
    }

    /** 🔥 Governance: Create a proposal to change the floor price */
    function createProposal(uint256 newPrice) external onlyOwner {
        proposals.push(Proposal(newPrice, 0, false, msg.sender));
        emit ProposalCreated(proposals.length - 1, newPrice);
    }

    function vote(uint256 proposalId) external {
        require(proposalId < proposals.length, "Invalid proposal");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        proposals[proposalId].voteCount += 1;
        hasVoted[proposalId][msg.sender] = true;

        emit VoteCast(msg.sender, proposalId);
    }

    function executeProposal(uint256 proposalId) external onlyOwner {
        require(proposalId < proposals.length, "Invalid proposal");
        require(proposals[proposalId].voteCount >= 10, "Not enough votes");
        require(!proposals[proposalId].executed, "Proposal already executed");

        floorPrice = proposals[proposalId].newFloorPrice;
        proposals[proposalId].executed = true;
    }
}
