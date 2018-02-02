/* solhint-disable not-rely-on-time */

pragma solidity ^0.4.18;

import 'zeppelin-solidity/contracts/ownership/Ownable.sol';
import 'zeppelin-solidity/contracts/token/ERC20/ERC20.sol';

import './MarketplaceManager.sol';


/**
 *  An address with `KEY` deposited in the `TimelockedEscrow` can only spend its `KEY`
 *  on whitelisted service providers, but not on anyone else until the expiry time is reached.
 *
 *  When the expiry time is reached it can instruct the escrow to `transfer` its deposited `KEY` to anyone.
 *
 *  An address can only `retrieve` its `KEY` from the escrow after the allotted expiry time.
 *
 *  If the address deposits additional `KEY` in escrow the expiry time is reset to an additional timelockPeriod.
 */
contract TimelockedEscrow is Ownable {

    uint private constant SECONDS_PER_DAY = 60 * 60 * 24;

    // the number of days during which a deposit can only be spent on a whitelisted address.
    uint public timelockPeriod;

    // the KEY token. It's an injected variable to allow for testing with a MockKEY.
    ERC20 private token;

    // mapping of whitelisted addresses.
    mapping(address => bool) private whitelisted;

    // mapping of addresses vs expiry times (in seconds since UNIX epoch)
    mapping(address => uint) private expiry;

    // mapping of addresses to the amounts they have on deposit.
    mapping(address => uint) private balances;

    /**
     *  Don't allow Zero addresses.
     *  @param serviceProvider — the address which must not be zero.
     */
    modifier nonZeroAddress(address serviceProvider) {
        require(serviceProvider != 0x0);
        _;
    }

    /**
     *  Require numbers that are not zero.
     *  Note: Negative value sent from a wallet become massive positive numbers so it
     *        is not actually possible to check against negative inputs.
     *        This modifier must be used in combination with other checks against the user's balance.
     *  @param number — the number which must not be zero.
     */
    modifier nonZeroNumber(uint number) {
        require(number > 0);
        _;
    }

    /**
     *  Ensures the message sender has the appropriate balance of KEY
     *  @param amount — the amount of KEY the message sender must have.
     */
    modifier senderCanAfford(uint amount) {
        require(token.balanceOf(msg.sender) >= amount);
        _;
    }

    /**
     *  Ensures the message sender has the appropriate balance of KEY on deposit.
     *  @param amount — the amount of KEY the message sender must have previously deposited.
     */
    modifier senderHasFundsOnDeposit(uint amount) {
        require(balances[msg.sender] >= amount);
        _;
    }

    /**
     *  Ensures the message sender has the approved the transfer of enough KEY by the escrow.
     *  @param amount — the amount of KEY the message sender must have approved the escrow to transfer.
     */
    modifier senderHasApprovedTransfer(uint amount) {
        require(token.allowance(msg.sender, this) >= amount);
        _;
    }

    /**
     *  Ensure that, if the timelock has not expired, then the recipient is whitelisted.
     *  @param recipient — The address you are trying to transfer KEY to.
     */
    modifier transferAllowed(address recipient) {
        if (now < expiry[msg.sender]) {
            require(whitelisted[recipient]);
        }
        _;
    }

    /**
     *  Emitted when a ServiceProvider's address has been whitelisted.
     *  @param serviceProvider — The address that was whitelisted.
     */
    event ServiceProviderWhitelisted(address serviceProvider);

    /**
     *  Emitted when a ServiceProvider's address has been removed from the whitelist.
     *  @param serviceProvider — The address that was unwhitelisted.
     */
    event ServiceProviderUnwhitelisted(address serviceProvider);

    /**
     *  Emitted when a an amount of KEY has been deposited.
     *  @param by — The address that deposited the KEY.
     *  @param amount — The amount of KEY deposited.
     *  @param expires — The UNIX epoch time (in seconds) the deposit lock expires.
     */
    event KEYDeposited(address by, uint amount, uint expires);

    /**
     *  Emitted when a an amount of KEY has been transferred.
     *  @param from — The address owns the KEY being sent.
     *  @param to — The address receiving the KEY. Must be a person not a contract.
     *  @param amount — The amount of KEY being sent.
     */
    event KEYTransferred(address from, address to, uint amount);

    /**
     *  Emitted when a an amount of KEY has been retrieved by its owner.
     *  @param to — The address receiving the KEY.
     *  @param amount — The amount of KEY being sent.
     */
    event KEYRetrieved(address to, uint amount);

    /**
     *  TimelockedEscrow constructor. Can only be invoked by a `MarketplaceManager`.
     *  @param _timelockPeriod — The number of days deposits are to remain locked.
     *  @param _token — The ERC20 token to use as currency. (Injected to ease testing)
     */
    function TimelockedEscrow(uint _timelockPeriod, ERC20 _token)
        public
        nonZeroAddress(_token)
    {
        timelockPeriod = _timelockPeriod;
        token = _token;
        MarketplaceManager manager = MarketplaceManager(msg.sender);
        owner = manager.owner();
    }

    /**
     *  Whitelist a Service Provider's address. Funds on deposit can only be spent
     *  on whitelisted Service Providers while timelocked.
     *  @param serviceProvider — The address of the Service Provider to whitelist.
     */
    function whitelist(address serviceProvider)
        external
        onlyOwner
        nonZeroAddress(serviceProvider)
    {
        whitelisted[serviceProvider] = true;
        ServiceProviderWhitelisted(serviceProvider);
    }

    /**
     *  Remove a Service Provider's address from the whitelist.
     *  @param serviceProvider — The address of the Service Provider to unwhitelist.
     */
    function unwhitelist(address serviceProvider)
        external
        onlyOwner
        nonZeroAddress(serviceProvider)
    {
        assert(whitelisted[serviceProvider]);
        whitelisted[serviceProvider] = false;
        ServiceProviderUnwhitelisted(serviceProvider);
    }

    /**
     *  When an amout is deposited its then 'locked' and can only be transferred
     *  to a whitelisted address during the timelock period.
     *  If someone then deposits more KEY, the KEY is added to the balance and
     *  and the timelock is reset to `now + timelockPeriod days`.
     *
     *  @param amount — The amount of KEY to deposit.
     */
    function deposit(uint amount)
        external
        nonZeroNumber(amount)
        senderCanAfford(amount)
        senderHasApprovedTransfer(amount)
    {
        token.transferFrom(msg.sender, this, amount);
        balances[msg.sender] += amount;
        uint expires = now + (timelockPeriod * SECONDS_PER_DAY);
        expiry[msg.sender] = expires;
        KEYDeposited(msg.sender, amount, expires);
    }

    /**
     *  Transfer an amount from the sender's Escrow account to a Service Provider.
     *  @param serviceProvider — The address to transfer the KEY to.
     *  @param amount — The amount of KEY to transfer.
     */
    function transfer(address serviceProvider, uint amount)
        external
        nonZeroAddress(serviceProvider)
        nonZeroNumber(amount)
        transferAllowed(serviceProvider)
        senderHasFundsOnDeposit(amount)
    {
        token.transfer(serviceProvider, amount);
        balances[msg.sender] -= amount;
        KEYTransferred(msg.sender, serviceProvider, amount);
    }

    /**
     *  Once a timelock has expired the KEY owner may retrieve their KEY from the Escrow.
     */
    function retrieve()
        external
        transferAllowed(msg.sender)
        senderHasFundsOnDeposit(1)
    {
        uint amount = balances[msg.sender];
        token.transfer(msg.sender, amount);
        KEYRetrieved(msg.sender, amount);
    }

    /**
     *  Test to see if an address has an amount of KEY on deposit.
     *  @param depositor — The address claiming to have KEY deposited.
     *  @param amount — The minumum amount of KEY they claim to have deposited.
     *  @return true if the depositor has at least the amount of KEY deposited.
     */
    function hasFunds(address depositor, uint amount)
        external
        view
        nonZeroAddress(depositor)
        nonZeroNumber(amount)
        returns (bool)
    {
        return balances[depositor] >= amount;
    }

    /**
     *  Test to see if the KEY on deposit by an address are still time locked.
     *  @param depositor — The address with KEY deposited.
     *  @return true if the depositor's time lock is current.
     */
    function areFundsTimelocked(address depositor)
        external
        view
        nonZeroAddress(depositor)
        returns (bool)
    {
        return now < expiry[depositor];
    }

    /**
     *  Test an address to see if it's been whitelisted.
     *  @param serviceProvider — The address of the Service Provider to test.
     *  @return true if the address has been whitelisted.
     */
    function isWhitelisted(address serviceProvider)
        external
        view
        nonZeroAddress(serviceProvider)
        returns (bool)
    {
        return whitelisted[serviceProvider];
    }
}
