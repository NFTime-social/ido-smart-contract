// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract IDO is Ownable, Pausable {
    using SafeERC20 for IERC20;
    // <================================ CONSTANTS ================================>
    uint8 constant TEAM_PERCENTAGE = 15;
    uint8 constant TEAM_FREEZE_DURATION_IN_MONTHS = 6;
    uint8 constant PUBLIC_PERCENTAGE = 15;
    uint8 constant PUBLIC_IMMEDIATE_UNLOCK_PERCENTAGE = 10;
    uint8 constant PUBLIC_UNLOCK_PER_MONTH_PERCENTAGE = 30;
    uint8 constant PUBLIC_LOCK_DURATION_IN_MONTHS = 3;
    
    // <================================ MODIFIERS ================================>
    modifier contractNotStarted() {
        require(_contractStarted == false, "IDO: The IDO contract has already started");
        _;
    }

    struct Share {
        address shareAddress;
        uint256 share;
        uint256 releaseTime;
    }

    // PSBuyer stands for Public Sale Buyer
    struct PSBuyer {
        address buyerAddress;
        uint256 lastWithdraw;
        uint256 initialTotalBalance;
        uint256 balance;
        uint256 busdLimit;
    }

    struct PublicSale {
        uint256 supply;
        uint256 unlockStartDate;
    }
    
    // <================================ CONSTRUCTOR AND INITIALIZER ================================>

    constructor(
        address nftmAddress, 
        address busdAddress,
        address teamAddress) 
    {
        require(nftmAddress != address(0), "IDO: NFTime token address must not be zero");
        require(busdAddress != address(0), "IDO: BUSD token address must not be zero");
        require(teamAddress != address(0), "IDO: Team address must not be zero");
        _nftm = IERC20(nftmAddress);
        _busd = IERC20(busdAddress);
        
        _teamShare.shareAddress = teamAddress;
        
        _teamShare.releaseTime = block.timestamp + _monthsToTimestamp(TEAM_FREEZE_DURATION_IN_MONTHS);
        _pause();
    }
    
    function initialize()
        external
        onlyOwner
        contractNotStarted
    {
        require(_contractStarted == false, "IDO: The IDO contract has been already initialized");
        uint256 totalSupply = _nftm.totalSupply();
        uint256 totalPercentage = TEAM_PERCENTAGE + PUBLIC_PERCENTAGE;
        uint256 initialSupply = (totalSupply * totalPercentage) / 100;

        _teamShare.share = (totalSupply * TEAM_PERCENTAGE) / 100;
        _publicSale.supply = (totalSupply * PUBLIC_PERCENTAGE) / 100;

        _contractStarted = true;
        _startDate = (block.timestamp - (block.timestamp % 1 days)) + 10 hours;
        transferTokensToContract(initialSupply);
        _unpause();
    }

    IERC20 public _nftm;
    IERC20 public _busd;
    uint256 public _startDate;
    Share public _teamShare;
    PublicSale public _publicSale;
    bool public _contractStarted; // true when contract has been initialized
    bool public _publicSaleEnded; // true if ended and false if still active
    mapping (address => PSBuyer) private psBuyers;

    // <================================ EXTERNAL FUNCTIONS ================================>

    function buyTokens(uint256 busdAmount) 
    external
    whenNotPaused
    returns(bool) {
        address buyer = _msgSender();
        require(!_publicSaleEnded, "IDO: Public sale has already finished");
        if(!isPublicSaleBuyer(buyer)) {
            PSBuyer storage psBuyer = psBuyers[buyer];
            psBuyer.buyerAddress = buyer;
            psBuyer.busdLimit = to18Decimals(500);
        }
        require(buyer != address(0), "IDO: Token issue to Zero address is prohibited");
        require(busdAmount > 0, "IDO: Provided BUSD amount must be higher than 0");
        require(_publicSale.supply > 0, "IDO: There are no public tokens left available for sale");
        require(busdAmount <= psBuyers[buyer].busdLimit, "IDO: The Provided BUSD amount exceeds allowed spend limit");
        require(psBuyers[buyer].busdLimit != 0, "IDO: This address has already purchased tokens for 500 BUSD");
        uint256 nftmPrice = getTokenPrice();
        uint256 tokensAmountToIssue = busdAmount / nftmPrice; // The total number of full tokens that will be issued. 1 Full NFTM token = 1000 tokens in full decimal precision
        require(tokensAmountToIssue > 0, "IDO: Provided BUSD amount is not sufficient to buy even one NFTM token");
        uint256 totalPrice = tokensAmountToIssue * nftmPrice; //Total price in BUSD to buy specific number of NFTM tokens
        uint256 megaTokensToIssue = toMegaToken(tokensAmountToIssue); //Total amount of NFTM tokens (in full decimal precision) to issue

        require(_issueTokens(buyer, totalPrice, megaTokensToIssue), "IDO: Token transfer failed");
        psBuyers[buyer].busdLimit -= totalPrice;
        return true;
    }

    function withdrawUnlockedTokens() 
    external
    whenNotPaused
    returns(bool) {
        address buyer = _msgSender();
        require(_publicSaleEnded, "IDO: Can not withdraw balance yet. Public Sale is not over yet");
        uint256 monthsSinceDate = _monthsSinceDate(_publicSale.unlockStartDate);
        require(monthsSinceDate > 0, "IDO: Can not withdraw balance yet");
        require(buyer != address(0), "IDO: Token issue to Zero address is prohibited");
        require(isPublicSaleBuyer(buyer), "IDO: The user hasn't participated in Public Sale or has already withdrawn all his balance");
        PSBuyer memory psBuyer = psBuyers[buyer];
        require(psBuyer.lastWithdraw < PUBLIC_LOCK_DURATION_IN_MONTHS, "IDO: Buyer has already withdrawn all available unlocked tokens");
        require(monthsSinceDate != psBuyer.lastWithdraw, "IDO: Buyer has already withdrawn tokens this month");
        uint256 unlockForMonths = monthsSinceDate - psBuyer.lastWithdraw;
        uint256 nftmToUnlock;
        if(monthsSinceDate >= 3)
        {
            nftmToUnlock = psBuyer.balance;
            _removePublicSaleBuyer(buyer);
        } else {
            nftmToUnlock = psBuyer.initialTotalBalance * (PUBLIC_UNLOCK_PER_MONTH_PERCENTAGE * unlockForMonths) / 100;
            psBuyers[buyer].balance -= nftmToUnlock;
            psBuyers[buyer].lastWithdraw = monthsSinceDate;
        }

        _nftm.safeTransfer(buyer, nftmToUnlock);
        
        emit TokensUnlocked(buyer, nftmToUnlock);
        return true;
    }

    function withdrawTeamShare() external onlyOwner whenNotPaused {
        require(_withdrawShare(_teamShare));
    }

    // <================================ ADMIN FUNCTIONS ================================>

    function pauseContract() external onlyOwner whenNotPaused
    {
        _pause();
    }

    function endPublicSale() external onlyOwner whenNotPaused 
    {

        _publicSale.unlockStartDate = _startDate + _daysSinceDate(_startDate) + 1 days;
        _publicSaleEnded = true;
    }

    function unPauseContract() external onlyOwner whenPaused
    {
        _unpause();
    }

    function isPublicSaleBuyer(address buyer) public view returns(bool) {
        if(psBuyers[buyer].initialTotalBalance != 0) {
            return true;
        }
        return false;
    }

    function transferTokensToContract(uint256 amount) public onlyOwner
    {
        address owner = _msgSender();
        _nftm.safeTransferFrom(owner, address(this), amount);
        emit TokensTransferedToStakingBalance(owner, amount);
    }

    function withdrawBUSD() external onlyOwner returns (bool) {
        address owner = _msgSender();
        uint256 balanceBUSD = _busd.balanceOf(address(this));
        require(balanceBUSD > 0, "IDO: Nothing to withdraw. Ido contract's BUSD balance is empty");
        _busd.safeTransfer(owner, balanceBUSD);
        return true;
    }

    function withdrawLeftPublicTokens() external onlyOwner returns (bool) {
        address owner = _msgSender();
        require(_publicSale.supply > 0, "IDO: Nothing to withdraw. Ido contract's BUSD balance is empty");
        _nftm.safeTransfer(owner, _publicSale.supply);
        return true;
    }

    function finalize() external onlyOwner {
        address owner = _msgSender();
        uint256 balanceBUSD = _busd.balanceOf(address(this));
        uint256 balanceNFTM = _nftm.balanceOf(address(this));
        if(balanceBUSD > 0) _busd.safeTransfer(owner, balanceBUSD);
        if(balanceNFTM > 0)  _nftm.safeTransfer(owner, balanceNFTM);
        selfdestruct(payable(owner));
    }

    // <================================ INTERNAL & PRIVATE FUNCTIONS ================================>
    function _withdrawShare(Share memory share) internal returns(bool) {
        require(block.timestamp >= share.releaseTime, "IDO: Time is not up. Cannot release share");
        _nftm.safeTransfer(share.shareAddress, share.share);

        emit ShareReleased(share.shareAddress, share.share);
        return true;
    }

    function _monthsSinceDate(uint256 _timestamp) private view returns(uint256){
        return  (block.timestamp - _timestamp) / 30 days;
    }

    function _daysSinceDate(uint256 _timestamp) private view returns(uint256){
        return  (block.timestamp - _timestamp) / 1 days ;
    }

    function getBuyerLimit(address buyer) external view returns(uint256){
        return psBuyers[buyer].busdLimit;
    }

    function getBuyerLockedBalance(address buyer) external view returns(uint256){
        return psBuyers[buyer].balance;
    }

    function getBuyerLastWithdraw(address buyer) external view returns(uint256){
        return psBuyers[buyer].lastWithdraw;
    }

    function getPublicSaleLeftSupply() external view returns(uint256){
        return _publicSale.supply;
    }

    function isPublicSaleActive() external view returns(bool) {
        return !_publicSaleEnded;
    }

    function isTokensUnlockActive() external view returns(bool) {
        uint256 monthsSinceDate = _monthsSinceDate(_publicSale.unlockStartDate);
        return monthsSinceDate > 0 && _publicSaleEnded;
    }

    function getTokenPrice() public view returns(uint256) {
        uint256 price = 90000000000000000; // 0,09$
        uint256 supply = _publicSale.supply;
        if(supply <= toMegaToken(12000000)) {
            price = 95000000000000000; //0,095$
        } else if (supply <= toMegaToken(9000000)) {
            price = 100000000000000000; //0,10$
        } else if (supply <= toMegaToken(6000000)) {
            price = 110000000000000000; //0,11$
        } else if (supply <= toMegaToken(3000000)) {
            price = 120000000000000000; //0,12$
        }

        return price;
    }
    
    function _issueTokens(address buyer, uint256 busdToPay, uint256 nftmToIssue) private returns(bool) {
        require(_busd.allowance(buyer, address(this)) >= busdToPay, "IDO: Not enough allowance to perform transfer. Please be sure to approve sufficient tokens amount");
        require(_busd.balanceOf(buyer) >= busdToPay, "IDO: Not enough BUSD available in buyer's balance. Please be sure to provide sufficient BUSD amount");
        uint256 nftmToUnlock = (nftmToIssue * PUBLIC_IMMEDIATE_UNLOCK_PERCENTAGE) / 100;
        
        _busd.safeTransferFrom(buyer, address(this), busdToPay);
        _nftm.safeTransfer(buyer, nftmToUnlock);
        _publicSale.supply -= nftmToIssue;

        PSBuyer storage psBuyer = psBuyers[buyer];
        psBuyer.buyerAddress = buyer;
        psBuyer.initialTotalBalance += nftmToIssue;
        psBuyer.balance += nftmToIssue - nftmToUnlock;

        emit TokensPurchased(buyer, busdToPay, nftmToIssue);
        return true;
    }

    function _removePublicSaleBuyer(address buyer) private {
        if(isPublicSaleBuyer(buyer)) {
            delete psBuyers[buyer];
        }
    }

    function _monthsToTimestamp(uint256 months) internal pure returns(uint256) {
        return months * 30 days;
    }

    function toMegaToken(uint256 amount) internal pure returns(uint256) {
        return amount * (10 ** decimals());
    }

    function to18Decimals(uint256 amount) internal pure returns(uint256) {
        return amount * (10 ** 18);
    }

    function decimals() internal pure returns(uint8) {
        return 6;
    }
    // <================================ EVENTS ================================>

    event TokensTransferedToStakingBalance(address indexed sender, uint256 indexed amount);

    event ShareReleased(address indexed beneficiary, uint256 indexed amount);

    event TokensPurchased(address indexed buyer, uint256 spentAmount, uint256 indexed issuedAmount);

    event TokensUnlocked(address indexed buyer, uint256 unlockedAmount);
}