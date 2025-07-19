// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// --- Interfaces ---
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    );
}

/// --- Custom Errors ---
error InsufficientBalance();
error InsufficientAllowance();
error ZeroAddress();
error NotEnoughETH();
error RewardPoolExhausted();
error InvalidProposal();
error ProposalExpired();
error ProposalAlreadyExecuted();
error AlreadyVoted();
error NoVotes();
error QuorumNotMet();
error NotOwner();
error TransferToZero();
error MintToZero();
error BurnFromZero();
error BurnAmountExceedsBalance();
error InvalidPriceFeed();
error InvalidBuybackWallet();
error NothingStaked();
error TokensLocked();
error AmountTooLow();
error InsufficientSupply();
error NoReserve();
error AboveFloor();
error ZeroBuyback();

/// --- ERC20 ---
contract ERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function transfer(address to, uint256 value) public returns (bool) {
        if (to == address(0)) revert TransferToZero();
        if (balanceOf[msg.sender] < value) revert InsufficientBalance();
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Only allow non-zero allowance if setting from zero, per best practice
    function approve(address spender, uint256 value) public returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        require(allowance[msg.sender][spender] == 0 || value == 0, "First set to zero");
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] += addedValue;
        emit Approval(msg.sender, spender, allowance[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        if (allowance[msg.sender][spender] < subtractedValue) revert InsufficientAllowance();
        allowance[msg.sender][spender] -= subtractedValue;
        emit Approval(msg.sender, spender, allowance[msg.sender][spender]);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < value) revert InsufficientBalance();
        if (allowance[from][msg.sender] < value) revert InsufficientAllowance();
        allowance[from][msg.sender] -= value;
        _transfer(from, to, value);
        return true;
    }

    function _mint(address to, uint256 value) internal {
        if (to == address(0)) revert MintToZero();
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        if (from == address(0)) revert BurnFromZero();
        if (balanceOf[from] < value) revert BurnAmountExceedsBalance();
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert TransferToZero();
        if (balanceOf[from] < value) revert InsufficientBalance();
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}

/// --- Ownable ---
contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

/// --- Pausable ---
contract Pausable is Ownable {
    bool public paused;
    event Paused(address account);
    event Unpaused(address account);

    modifier whenNotPaused() {
        require(!paused, "Pausable: paused");
        _;
    }

    modifier whenPaused() {
        require(paused, "Pausable: not paused");
        _;
    }

    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit Unpaused(msg.sender);
    }
}

/// --- ReentrancyGuard ---
contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/// --- Main Token ---
contract ReachToken is ERC20("Reach Token", "9D-RC"), Pausable, ReentrancyGuard {
    uint256 public constant TOTAL_SUPPLY = 18_000_000_000 * 1e18;
    uint256 public constant MIN_PURCHASE = 0.01 ether;
    uint256 public constant STAKE_LOCKUP = 1 days;

    uint256 public floorPrice = 27 * 1e18; // $27 base floor in 18 decimals
    uint256 public basePrice = 27 * 1e18;
    uint256 public curveK = 1 * 1e12;
    uint256 public tokensSold;

    uint256 public buybackReserve;
    uint256 public buybackAllocation = 50; // % of ETH for buybacks
    uint256 public stakingAllocation = 30; // % of ETH for staking (future)
    address public buybackWallet;

    AggregatorV3Interface public priceFeed;

    mapping(address => uint256) public stakingBalance;
    mapping(address => uint256) public lastStakeTime;

    uint256 public stakingRewardRate = 100; // 1% APR in basis points
    uint256 public totalRewardPool = 100_000_000 * 1e18; // 100M token reward cap

    struct Proposal {
        uint256 newFloorPrice;
        string description;
        uint256 voteCount;
        uint256 deadline;
        bool executed;
        address creator;
    }

    Proposal[] public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event TokensBought(address indexed buyer, uint256 ethSpent, uint256 tokensReceived);
    event BuybackExecuted(uint256 amount, uint256 price);
    event TokensStaked(address indexed user, uint256 amount);
    event TokensUnstaked(address indexed user, uint256 amount, uint256 reward);
    event ProposalCreated(uint256 proposalId, uint256 newFloorPrice, string description, uint256 deadline);
    event ProposalExecuted(uint256 proposalId, uint256 newFloorPrice);
    event VoteCast(address voter, uint256 proposalId, uint256 votes);
    event EmergencyUnstake(address indexed user, uint256 amount);

    constructor(address _priceFeed, address _buybackWallet) {
        if (_priceFeed == address(0)) revert InvalidPriceFeed();
        if (_buybackWallet == address(0)) revert InvalidBuybackWallet();

        priceFeed = AggregatorV3Interface(_priceFeed);
        buybackWallet = _buybackWallet;

        _mint(msg.sender, TOTAL_SUPPLY);
        transferOwnership(msg.sender);
    }

    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        if (address(this).balance < amount) revert NotEnoughETH();
        to.transfer(amount);
    }

    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , ,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid Chainlink price");
        return uint256(price) * 1e10; // Convert from 8 to 18 decimals
    }

    function getCurvePrice() public view returns (uint256) {
        return basePrice + (curveK * (tokensSold ** 2) / 1e36);
    }

    function getTokenPrice() public view returns (uint256) {
        uint256 chainlinkPrice = getLatestPrice();
        uint256 curvePrice = getCurvePrice();
        uint256 price = curvePrice;

        if (chainlinkPrice > price) price = chainlinkPrice;
        if (floorPrice > price) price = floorPrice;
        return price;
    }

function vote(uint256 proposalId) external whenNotPaused {
    if (proposalId >= proposals.length) revert InvalidProposal();
    Proposal storage p = proposals[proposalId];
    if (block.timestamp >= p.deadline) revert ProposalExpired();
    if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

    uint256 votes = balanceOf[msg.sender];
    if (votes == 0) revert NoVotes();

    p.voteCount += votes;
    hasVoted[proposalId][msg.sender] = true;

    emit VoteCast(msg.sender, proposalId, 1); // Always 1 vote per wallet

    receive() external payable {
        require(tx.origin == msg.sender, "No contracts allowed");
        buyTokens();
    }

    fallback() external payable {
        require(tx.origin == msg.sender, "No contracts allowed");
        buyTokens();
    }

    function executeBuyback() public onlyOwner nonReentrant whenNotPaused {
        uint256 currentPrice = getLatestPrice();
        if (currentPrice >= floorPrice) revert AboveFloor();
        if (buybackReserve == 0) revert NoReserve();

        uint256 buyAmount = (buybackReserve * 1e18) / currentPrice;
        if (buyAmount == 0) revert ZeroBuyback();

        buybackReserve = 0;

        // If buyback wallet doesn't have enough tokens, mint and immediately burn for transparency.
        if (balanceOf[buybackWallet] >= buyAmount) {
            _burn(buybackWallet, buyAmount);
        } else {
            _mint(buybackWallet, buyAmount);
            _burn(buybackWallet, buyAmount);
        }

        emit BuybackExecuted(buyAmount, currentPrice);
    }

    function stakeTokens(uint256 amount) external nonReentrant whenNotPaused {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        if (amount == 0) revert AmountTooLow();

        _transfer(msg.sender, address(this), amount);
        stakingBalance[msg.sender] += amount;
        lastStakeTime[msg.sender] = block.timestamp;

        emit TokensStaked(msg.sender, amount);
    }

    function calculateReward(address user) public view returns (uint256) {
        if (stakingBalance[user] == 0) return 0;
        uint256 timeStaked = block.timestamp - lastStakeTime[user];
        return (stakingBalance[user] * stakingRewardRate * timeStaked) / (10000 * 365 days);
    }

    function unstakeTokens() external nonReentrant whenNotPaused {
        if (stakingBalance[msg.sender] == 0) revert NothingStaked();
        if (block.timestamp < lastStakeTime[msg.sender] + STAKE_LOCKUP) revert TokensLocked();

        uint256 amount = stakingBalance[msg.sender];
        uint256 reward = calculateReward(msg.sender);

        if (totalRewardPool < reward) revert RewardPoolExhausted();
        totalRewardPool -= reward;

        stakingBalance[msg.sender] = 0;
        lastStakeTime[msg.sender] = 0;

        _transfer(address(this), msg.sender, amount);
        if (reward > 0) _mint(msg.sender, reward);

        emit TokensUnstaked(msg.sender, amount, reward);
    }

    function emergencyUnstake(address user) external onlyOwner whenPaused {
        uint256 amount = stakingBalance[user];
        if (amount == 0) revert NothingStaked();

        stakingBalance[user] = 0;
        lastStakeTime[user] = 0;

        _transfer(address(this), user, amount);
        emit EmergencyUnstake(user, amount);
    }

    function createProposal(uint256 newPrice, string calldata description) external onlyOwner whenNotPaused {
        if (newPrice == 0) revert AmountTooLow();

        proposals.push(Proposal({
            newFloorPrice: newPrice,
            description: description,
            voteCount: 0,
            deadline: block.timestamp + 3 days,
            executed: false,
            creator: msg.sender
        }));

        emit ProposalCreated(proposals.length - 1, newPrice, description, block.timestamp + 3 days);
    }

    function vote(uint256 proposalId) external whenNotPaused {
        if (proposalId >= proposals.length) revert InvalidProposal();
        Proposal storage p = proposals[proposalId];
        if (block.timestamp >= p.deadline) revert ProposalExpired();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        uint256 votes = balanceOf[msg.sender];
        if (votes == 0) revert NoVotes();

        p.voteCount += votes;
        hasVoted[proposalId][msg.sender] = true;

        emit VoteCast(msg.sender, proposalId, votes);
    }

    function executeProposal(uint256 proposalId) external onlyOwner whenNotPaused {
        if (proposalId >= proposals.length) revert InvalidProposal();
        Proposal storage p = proposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (block.timestamp < p.deadline) revert ProposalExpired();
        if (p.voteCount < tokensSold / 10) revert QuorumNotMet();

        floorPrice = p.newFloorPrice;
        p.executed = true;

        emit ProposalExecuted(proposalId, p.newFloorPrice);
    }
}
