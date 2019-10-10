pragma solidity ^0.5.3;

import "openzeppelin-solidity/contracts/math/Math.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";

import "./interfaces/IValidators.sol";

import "../identity/interfaces/IRandom.sol";

import "../common/Initializable.sol";
import "../common/FixidityLib.sol";
import "../common/linkedlists/AddressLinkedList.sol";
import "../common/UsingRegistry.sol";
import "../common/UsingPrecompiles.sol";


/**
 * @title A contract for registering and electing Validator Groups and Validators.
 */
contract Validators is
  IValidators, Ownable, ReentrancyGuard, Initializable, UsingRegistry, UsingPrecompiles {

  using FixidityLib for FixidityLib.Fraction;
  using AddressLinkedList for LinkedList.List;
  using SafeMath for uint256;
  using BytesLib for bytes;

  address constant PROOF_OF_POSSESSION = address(0xff - 4);
  uint256 constant MAX_INT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

  // If an account has not registered a validator or group, these values represent the minimum
  // amount of Locked Gold required to do so.
  // If an account has a registered a validator or validator group, these values represent the
  // minimum amount of Locked Gold required in order to earn epoch rewards. Furthermore, the
  // account will not be able to unlock Gold if it would cause the account to fall below
  // these values.
  // If an account has deregistered a validator or validator group and is still subject to the
  // `DeregistrationLockup`, the account will not be able to unlock Gold if it would cause the
  // account to fall below these values.
  struct BalanceRequirements {
    uint256 group;
    uint256 validator;
  }

  // After deregistering a validator or validator group, the account will remain subject to the
  // current balance requirements for this long (in seconds).
  struct DeregistrationLockups {
    uint256 group;
    uint256 validator;
  }

  // Stores the timestamps at which deregistration of a validator or validator group occurred.
  struct DeregistrationTimestamps {
    uint256 group;
    uint256 validator;
  }

  struct ValidatorGroup {
    string name;
    string url;
    LinkedList.List members;
    // TODO(asa): Add a function that allows groups to update their commission.
    FixidityLib.Fraction commission;
  }

  struct MembershipHistoryEntry {
    uint256 epochNumber;
    address group;
  }

  struct MembershipHistory {
    uint256 head;
    MembershipHistoryEntry[] entries;
  }

  struct Validator {
    string name;
    string url;
    bytes publicKeysData;
    address affiliation;
    FixidityLib.Fraction score;
    MembershipHistory membershipHistory;
  }

  struct ValidatorScoreParameters {
    uint256 exponent;
    FixidityLib.Fraction adjustmentSpeed;
  }

  mapping(address => ValidatorGroup) private groups;
  mapping(address => Validator) private validators;
  mapping(address => DeregistrationTimestamps) private deregistrationTimestamps;
  address[] private _groups;
  address[] private _validators;
  BalanceRequirements public balanceRequirements;
  DeregistrationLockups public deregistrationLockups;
  ValidatorScoreParameters private validatorScoreParameters;
  uint256 public validatorEpochPayment;
  uint256 public membershipHistoryLength;
  uint256 public maxGroupSize;

  event Debug(uint256 value);
  event MaxGroupSizeSet(
    uint256 size
  );

  event ValidatorEpochPaymentSet(
    uint256 value
  );

  event ValidatorScoreParametersSet(
    uint256 exponent,
    uint256 adjustmentSpeed
  );

  event BalanceRequirementsSet(
    uint256 group,
    uint256 validator
  );

  event DeregistrationLockupsSet(
    uint256 group,
    uint256 validator
  );

  event ValidatorRegistered(
    address indexed validator,
    string name,
    string url,
    bytes publicKeysData
  );

  event ValidatorDeregistered(
    address indexed validator
  );

  event ValidatorAffiliated(
    address indexed validator,
    address indexed group
  );

  event ValidatorDeaffiliated(
    address indexed validator,
    address indexed group
  );

  event ValidatorGroupRegistered(
    address indexed group,
    string name,
    string url
  );

  event ValidatorGroupDeregistered(
    address indexed group
  );

  event ValidatorGroupMemberAdded(
    address indexed group,
    address indexed validator
  );

  event ValidatorGroupMemberRemoved(
    address indexed group,
    address indexed validator
  );

  event ValidatorGroupMemberReordered(
    address indexed group,
    address indexed validator
  );

  modifier onlyVm() {
    require(msg.sender == address(0));
    _;
  }

  /**
   * @notice Initializes critical variables.
   * @param registryAddress The address of the registry contract.
   * @param groupRequirement The minimum locked gold needed to register a group.
   * @param validatorRequirement The minimum locked gold needed to register a validator.
   * @param groupLockup The duration the above gold remains locked after deregistration.
   * @param validatorLockup The duration the above gold remains locked after deregistration.
   * @param validatorScoreExponent The exponent used in calculating validator scores.
   * @param validatorScoreAdjustmentSpeed The speed at which validator scores are adjusted.
   * @param _validatorEpochPayment The duration the above gold remains locked after deregistration.
   * @param _membershipHistoryLength The max number of entries for validator membership history.
   * @param _maxGroupSize The maximum group size.
   * @dev Should be called only once.
   */
  function initialize(
    address registryAddress,
    uint256 groupRequirement,
    uint256 validatorRequirement,
    uint256 groupLockup,
    uint256 validatorLockup,
    uint256 validatorScoreExponent,
    uint256 validatorScoreAdjustmentSpeed,
    uint256 _validatorEpochPayment,
    uint256 _membershipHistoryLength,
    uint256 _maxGroupSize
  )
    external
    initializer
  {
    require(validatorScoreAdjustmentSpeed <= FixidityLib.fixed1().unwrap());
    _transferOwnership(msg.sender);
    setRegistry(registryAddress);
    balanceRequirements = BalanceRequirements(groupRequirement, validatorRequirement);
    deregistrationLockups = DeregistrationLockups(groupLockup, validatorLockup);
    validatorScoreParameters = ValidatorScoreParameters(
      validatorScoreExponent,
      FixidityLib.wrap(validatorScoreAdjustmentSpeed)
    );
    validatorEpochPayment = _validatorEpochPayment;
    membershipHistoryLength = _membershipHistoryLength;
    maxGroupSize = _maxGroupSize;
  }

  /**
   * @notice Updates the maximum number of members a group can have.
   * @param size The maximum group size.
   * @return True upon success.
   */
  function setMaxGroupSize(uint256 size) external onlyOwner returns (bool) {
    require(0 < size && size != maxGroupSize);
    maxGroupSize = size;
    emit MaxGroupSizeSet(size);
    return true;
  }

  /**
   * @notice Sets the per-epoch payment in Celo Dollars for validators, less group commission.
   * @param value The value in Celo Dollars.
   * @return True upon success.
   */
  function setValidatorEpochPayment(uint256 value) external onlyOwner returns (bool) {
    require(value != validatorEpochPayment);
    validatorEpochPayment = value;
    emit ValidatorEpochPaymentSet(value);
    return true;
  }

  /**
   * @notice Updates the validator score parameters.
   * @param exponent The exponent used in calculating the score.
   * @param adjustmentSpeed The speed at which the score is adjusted.
   * @return True upon success.
   */
  function setValidatorScoreParameters(
    uint256 exponent,
    uint256 adjustmentSpeed
  )
    external
    onlyOwner
    returns (bool)
  {
    require(adjustmentSpeed <= FixidityLib.fixed1().unwrap());
    require(
      exponent != validatorScoreParameters.exponent ||
      !FixidityLib.wrap(adjustmentSpeed).equals(validatorScoreParameters.adjustmentSpeed)
    );
    validatorScoreParameters = ValidatorScoreParameters(
      exponent,
      FixidityLib.wrap(adjustmentSpeed)
    );
    emit ValidatorScoreParametersSet(exponent, adjustmentSpeed);
    return true;
  }

  /**
   * @notice Returns the maximum number of members a group can add.
   * @return The maximum number of members a group can add.
   */
  function getMaxGroupSize() external view returns (uint256) {
    return maxGroupSize;
  }

  /**
   * @notice Updates the minimum gold requirements to register a validator group or validator.
   * @param groupRequirement The minimum locked gold needed to register a group.
   * @param validatorRequirement The minimum locked gold needed to register a validator.
   * @return True upon success.
   * @dev The new requirement is only enforced for future validator or group registrations.
   */
  // TODO(asa): Allow validators to adjust their LockedGold MustMaintain if the registration
  // requirements fall.
  function setBalanceRequirements(
    uint256 groupRequirement,
    uint256 validatorRequirement
  )
    external
    onlyOwner
    returns (bool)
  {
    require(
      groupRequirement != balanceRequirements.group ||
      validatorRequirement != balanceRequirements.validator
    );
    balanceRequirements = BalanceRequirements(groupRequirement, validatorRequirement);
    emit BalanceRequirementsSet(groupRequirement, validatorRequirement);
    return true;
  }

  /**
   * @notice Updates the duration for which gold remains locked after deregistration.
   * @param groupLockup The duration for groups in seconds.
   * @param validatorLockup The duration for validators in seconds.
   * @return True upon success.
   * @dev The new requirement is only enforced for future validator or group deregistrations.
   */
  function setDeregistrationLockups(
    uint256 groupLockup,
    uint256 validatorLockup
  )
    external
    onlyOwner
    returns (bool)
  {
    require(
      groupLockup != deregistrationLockups.group ||
      validatorLockup != deregistrationLockups.validator
    );
    deregistrationLockups = DeregistrationLockups(groupLockup, validatorLockup);
    emit DeregistrationLockupsSet(groupLockup, validatorLockup);
    return true;
  }

  /**
   * @notice Registers a validator unaffiliated with any validator group.
   * @param name A name for the validator.
   * @param url A URL for the validator.
   * @param publicKeysData Comprised of three tightly-packed elements:
   *    - publicKey - The public key that the validator is using for consensus, should match
   *      msg.sender. 64 bytes.
   *    - blsPublicKey - The BLS public key that the validator is using for consensus, should pass
   *      proof of possession. 48 bytes.
   *    - blsPoP - The BLS public key proof of possession. 96 bytes.
   * @return True upon success.
   * @dev Fails if the account is already a validator or validator group.
   * @dev Fails if the account does not have sufficient weight.
   */
  function registerValidator(
    string calldata name,
    string calldata url,
    bytes calldata publicKeysData
  )
    external
    nonReentrant
    returns (bool)
  {
    require(
      bytes(name).length > 0 &&
      bytes(url).length > 0 &&
      // secp256k1 public key + BLS public key + BLS proof of possession
      publicKeysData.length == (64 + 48 + 96)
    );
    // Use the proof of possession bytes
    require(checkProofOfPossession(publicKeysData.slice(64, 48 + 96)));

    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    require(!isValidator(account) && !isValidatorGroup(account));
    require(meetsValidatorBalanceRequirements(account));

    validators[account].name = name;
    validators[account].url = url;
    validators[account].publicKeysData = publicKeysData;
    _validators.push(account);
    updateMembershipHistory(account, address(0));
    emit ValidatorRegistered(account, name, url, publicKeysData);
    return true;
  }

  /**
   * @notice Checks a BLS proof of possession.
   * @param proofOfPossessionBytes The public key and signature of the proof of possession.
   * @return True upon success.
   */
  function checkProofOfPossession(bytes memory proofOfPossessionBytes) private returns (bool) {
    bool success;
    (success, ) = PROOF_OF_POSSESSION.call.value(0).gas(gasleft())(proofOfPossessionBytes);
    return success;
  }

  /**
   * @notice Returns whether an account meets the requirements to register a validator.
   * @param account The account.
   * @return Whether an account meets the requirements to register a validator.
   */
  function meetsValidatorBalanceRequirements(address account) public view returns (bool) {
    return getLockedGold().getAccountTotalLockedGold(account) >= balanceRequirements.validator;
  }

  /**
   * @notice Returns whether an account meets the requirements to register a group.
   * @param account The account.
   * @return Whether an account meets the requirements to register a group.
   */
  function meetsValidatorGroupBalanceRequirements(address account) public view returns (bool) {
    return getLockedGold().getAccountTotalLockedGold(account) >= balanceRequirements.group;
  }

  function getValidatorScoreParameters() external view returns (uint256, uint256) {
    return (validatorScoreParameters.exponent, validatorScoreParameters.adjustmentSpeed.unwrap());
  }

  function getMembershipHistory(
    address account
  )
    external
    view
    returns (uint256[] memory, address[] memory)
  {
    MembershipHistoryEntry[] memory entries = validators[account].membershipHistory.entries;
    uint256[] memory epochs = new uint256[](entries.length);
    address[] memory membershipGroups = new address[](entries.length);
    for (uint256 i = 0; i < entries.length; i = i.add(1)) {
      epochs[i] = entries[i].epochNumber;
      membershipGroups[i] = entries[i].group;
    }
    return (epochs, membershipGroups);
  }

  /**
   * @notice Updates a validator's score based on its uptime for the epoch.
   * @param validator The address of the validator.
   * @param uptime The Fixidity representation of the validator's uptime, between 0 and 1.
   * @return True upon success.
   */
  function updateValidatorScore(address validator, uint256 uptime) external onlyVm() {
    _updateValidatorScore(validator, uptime);
  }

  /**
   * @notice Updates a validator's score based on its uptime for the epoch.
   * @param validator The address of the validator.
   * @param uptime The Fixidity representation of the validator's uptime, between 0 and 1.
   * @return True upon success.
   */
  function _updateValidatorScore(address validator, uint256 uptime) internal {
    address account = getLockedGold().getAccountFromValidator(validator);
    require(isValidator(account), "isvalidator");
    require(uptime <= FixidityLib.fixed1().unwrap(), "uptime");

    uint256 numerator;
    uint256 denominator;
    (numerator, denominator) = fractionMulExp(
      FixidityLib.fixed1().unwrap(),
      FixidityLib.fixed1().unwrap(),
      uptime,
      FixidityLib.fixed1().unwrap(),
      validatorScoreParameters.exponent,
      18
    );

    FixidityLib.Fraction memory epochScore = FixidityLib.wrap(numerator).divide(
      FixidityLib.wrap(denominator)
    );
    FixidityLib.Fraction memory newComponent = validatorScoreParameters.adjustmentSpeed.multiply(
      epochScore
    );

    FixidityLib.Fraction memory currentComponent = FixidityLib.fixed1().subtract(
      validatorScoreParameters.adjustmentSpeed
    );
    currentComponent = currentComponent.multiply(validators[account].score);
    validators[account].score = FixidityLib.wrap(
      Math.min(
        epochScore.unwrap(),
        newComponent.add(currentComponent).unwrap()
      )
    );
  }

  function distributeEpochPayment(address validator) external onlyVm() {
    _distributeEpochPayment(validator);
  }

  function _distributeEpochPayment(address validator) internal {
    address account = getLockedGold().getAccountFromValidator(validator);
    require(isValidator(account));
    address group = getMembershipInLastEpoch(account);
    // Both the validator and the group must maintain the minimum locked gold balance in order to
    // receive epoch payments.
    bool meetsBalanceRequirements = (
      getLockedGold().getAccountTotalLockedGold(group) >= getAccountBalanceRequirement(group) &&
      getLockedGold().getAccountTotalLockedGold(account) >= getAccountBalanceRequirement(account)
    );
    if (meetsBalanceRequirements) {
      FixidityLib.Fraction memory totalPayment = FixidityLib.newFixed(
        validatorEpochPayment
      ).multiply(validators[account].score);
      uint256 groupPayment = totalPayment.multiply(groups[group].commission).fromFixed();
      uint256 validatorPayment = totalPayment.fromFixed().sub(groupPayment);
      getStableToken().mint(group, groupPayment);
      getStableToken().mint(account, validatorPayment);
    }
  }

  /**
   * @notice De-registers a validator, removing it from the group for which it is a member.
   * @param index The index of this validator in the list of all validators.
   * @return True upon success.
   * @dev Fails if the account is not a validator.
   */
  function deregisterValidator(uint256 index) external nonReentrant returns (bool) {
    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    require(isValidator(account));
    Validator storage validator = validators[account];
    if (validator.affiliation != address(0)) {
      _deaffiliate(validator, account);
    }
    delete validators[account];
    deleteElement(_validators, account, index);
    deregistrationTimestamps[account].validator = now;
    emit ValidatorDeregistered(account);
    return true;
  }

  /**
   * @notice Affiliates a validator with a group, allowing it to be added as a member.
   * @param group The validator group with which to affiliate.
   * @return True upon success.
   * @dev De-affiliates with the previously affiliated group if present.
   */
  function affiliate(address group) external nonReentrant returns (bool) {
    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    require(isValidator(account) && isValidatorGroup(group));
    Validator storage validator = validators[account];
    if (validator.affiliation != address(0)) {
      _deaffiliate(validator, account);
    }
    validator.affiliation = group;
    emit ValidatorAffiliated(account, group);
    return true;
  }

  /**
   * @notice De-affiliates a validator, removing it from the group for which it is a member.
   * @return True upon success.
   * @dev Fails if the account is not a validator with non-zero affiliation.
   */
  function deaffiliate() external nonReentrant returns (bool) {
    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    require(isValidator(account));
    Validator storage validator = validators[account];
    require(validator.affiliation != address(0));
    _deaffiliate(validator, account);
    return true;
  }

  /**
   * @notice Registers a validator group with no member validators.
   * @param name A name for the validator group.
   * @param url A URL for the validator group.
   * @return True upon success.
   * @dev Fails if the account is already a validator or validator group.
   * @dev Fails if the account does not have sufficient weight.
   */
  function registerValidatorGroup(
    string calldata name,
    string calldata url,
    uint256 commission
  )
    external
    nonReentrant
    returns (bool)
  {
    require(bytes(name).length > 0);
    require(bytes(url).length > 0);
    require(commission <= FixidityLib.fixed1().unwrap(), "Commission can't be greater than 100%");
    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    require(!isValidator(account) && !isValidatorGroup(account));
    require(meetsValidatorGroupBalanceRequirements(account));

    ValidatorGroup storage group = groups[account];
    group.name = name;
    group.url = url;
    group.commission = FixidityLib.wrap(commission);
    _groups.push(account);
    emit ValidatorGroupRegistered(account, name, url);
    return true;
  }

  /**
   * @notice De-registers a validator group.
   * @param index The index of this validator group in the list of all validator groups.
   * @return True upon success.
   * @dev Fails if the account is not a validator group with no members.
   */
  function deregisterValidatorGroup(uint256 index) external nonReentrant returns (bool) {
    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    // Only empty Validator Groups can be deregistered.
    require(isValidatorGroup(account) && groups[account].members.numElements == 0);
    delete groups[account];
    deleteElement(_groups, account, index);
    deregistrationTimestamps[account].group = now;
    emit ValidatorGroupDeregistered(account);
    return true;
  }

  /**
   * @notice Adds a member to the end of a validator group's list of members.
   * @param validator The validator to add to the group
   * @return True upon success.
   * @dev Fails if `validator` has not set their affiliation to this account.
   * @dev Fails if the group has zero members.
   */
  function addMember(address validator) external nonReentrant returns (bool) {
    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    require(groups[account].members.numElements > 0);
    return _addMember(account, validator, address(0), address(0));
  }

  /**
   * @notice Adds the first member to a group's list of members and marks it eligible for election.
   * @param validator The validator to add to the group
   * @param lesser The address of the group that has received fewer votes than this group.
   * @param greater The address of the group that has received more votes than this group.
   * @return True upon success.
   * @dev Fails if `validator` has not set their affiliation to this account.
   * @dev Fails if the group has > 0 members.
   */
  function addFirstMember(
    address validator,
    address lesser,
    address greater
  )
    external
    nonReentrant
    returns (bool)
  {
    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    require(groups[account].members.numElements == 0);
    return _addMember(account, validator, lesser, greater);
  }

  /**
   * @notice Adds a member to the end of a validator group's list of members.
   * @param group The address of the validator group.
   * @param validator The validator to add to the group.
   * @param lesser The address of the group that has received fewer votes than this group.
   * @param greater The address of the group that has received more votes than this group.
   * @return True upon success.
   * @dev Fails if `validator` has not set their affiliation to this account.
   */
  function _addMember(
    address group,
    address validator,
    address lesser,
    address greater
  )
    private
    returns (bool)
  {
    require(isValidatorGroup(group) && isValidator(validator));
    ValidatorGroup storage _group = groups[group];
    require(_group.members.numElements < maxGroupSize, "group would exceed maximum size");
    require(validators[validator].affiliation == group && !_group.members.contains(validator));
    _group.members.push(validator);
    if (_group.members.numElements == 1) {
      getElection().markGroupEligible(group, lesser, greater);
    }
    updateMembershipHistory(validator, group);
    emit ValidatorGroupMemberAdded(group, validator);
    return true;
  }

  /**
   * @notice Removes a member from a validator group.
   * @param validator The validator to remove from the group
   * @return True upon success.
   * @dev Fails if `validator` is not a member of the account's group.
   */
  function removeMember(address validator) external nonReentrant returns (bool) {
    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    require(isValidatorGroup(account) && isValidator(validator), "is not group and validator");
    return _removeMember(account, validator);
  }

  /**
   * @notice Reorders a member within a validator group.
   * @param validator The validator to reorder.
   * @param lesserMember The member who will be behind `validator`, or 0 if `validator` will be the
   *   last member.
   * @param greaterMember The member who will be ahead of `validator`, or 0 if `validator` will be
   *   the first member.
   * @return True upon success.
   * @dev Fails if `validator` is not a member of the account's validator group.
   */
  function reorderMember(
    address validator,
    address lesserMember,
    address greaterMember
  )
    external
    nonReentrant
    returns (bool)
  {
    address account = getLockedGold().getAccountFromActiveValidator(msg.sender);
    require(isValidatorGroup(account) && isValidator(validator));
    ValidatorGroup storage group = groups[account];
    require(group.members.contains(validator));
    group.members.update(validator, lesserMember, greaterMember);
    emit ValidatorGroupMemberReordered(account, validator);
    return true;
  }

  /**
   * @notice Returns the locked gold balance requirement for the supplied account.
   * @param account The account that may have to meet locked gold balance requirements.
   * @return The locked gold balance requirement for the supplied account.
   */
  function getAccountBalanceRequirement(address account) public view returns (uint256) {
    DeregistrationTimestamps storage timestamps = deregistrationTimestamps[account];
    if (
      isValidator(account) ||
      (timestamps.validator > 0 && now < timestamps.validator.add(deregistrationLockups.validator))
    ) {
      return balanceRequirements.validator;
    }
    if (
      isValidatorGroup(account) ||
      (timestamps.group > 0 && now < timestamps.group.add(deregistrationLockups.group))
    ) {
      return balanceRequirements.group;
    }
    return 0;
  }

  function getDeregistrationTimestamps(address account) external view returns (uint256, uint256) {
    return (deregistrationTimestamps[account].group, deregistrationTimestamps[account].validator);
  }

  /**
   * @notice Returns validator information.
   * @param account The account that registered the validator.
   * @return The unpacked validator struct.
   */
  function getValidator(
    address account
  )
    external
    view
    returns (
      string memory name,
      string memory url,
      bytes memory publicKeysData,
      address affiliation,
      uint256 score
    )
  {
    require(isValidator(account));
    Validator storage validator = validators[account];
    return (
      validator.name,
      validator.url,
      validator.publicKeysData,
      validator.affiliation,
      validator.score.unwrap()
    );
  }

  /**
   * @notice Returns validator group information.
   * @param account The account that registered the validator group.
   * @return The unpacked validator group struct.
   */
  function getValidatorGroup(
    address account
  )
    external
    view
    returns (string memory, string memory, address[] memory, uint256)
  {
    require(isValidatorGroup(account));
    ValidatorGroup storage group = groups[account];
    return (group.name, group.url, group.members.getKeys(), group.commission.unwrap());
  }

  /**
   * @notice Returns the number of members in a validator group.
   * @param account The address of the validator group.
   * @return The number of members in a validator group.
   */
  function getGroupNumMembers(address account) public view returns (uint256) {
    require(isValidatorGroup(account));
    return groups[account].members.numElements;
  }

  /**
   * @notice Returns the top n group members for a particular group.
   * @param account The address of the validator group.
   * @param n The number of members to return.
   * @return The top n group members for a particular group.
   */
  function getTopGroupValidators(
    address account,
    uint256 n
  )
    external
    view
    returns (address[] memory)
  {
    address[] memory topAccounts = groups[account].members.headN(n);
    address[] memory topValidators = new address[](n);
    for (uint256 i = 0; i < n; i = i.add(1)) {
      topValidators[i] = getLockedGold().getValidatorFromAccount(topAccounts[i]);
    }
    return topValidators;
  }

  /**
   * @notice Returns the number of members in the provided validator groups.
   * @param accounts The addresses of the validator groups.
   * @return The number of members in the provided validator groups.
   */
  function getGroupsNumMembers(
    address[] calldata accounts
  )
    external
    view
    returns (uint256[] memory)
  {
    uint256[] memory numMembers = new uint256[](accounts.length);
    for (uint256 i = 0; i < accounts.length; i = i.add(1)) {
      numMembers[i] = getGroupNumMembers(accounts[i]);
    }
    return numMembers;
  }

  /**
   * @notice Returns the number of registered validators.
   * @return The number of registered validators.
   */
  function getNumRegisteredValidators() external view returns (uint256) {
    return _validators.length;
  }

  /**
   * @notice Returns the Locked Gold requirements to register a validator or group.
   * @return The locked gold requirements to register a validator or group.
   */
  function getBalanceRequirements() external view returns (uint256, uint256) {
    return (balanceRequirements.group, balanceRequirements.validator);
  }

  /**
   * @notice Returns the lockup periods after deregistering groups and validators.
   * @return The lockup periods after deregistering groups and validators.
   */
  function getDeregistrationLockups() external view returns (uint256, uint256) {
    return (deregistrationLockups.group, deregistrationLockups.validator);
  }

  /**
   * @notice Returns the list of registered validator accounts.
   * @return The list of registered validator accounts.
   */
  function getRegisteredValidators() external view returns (address[] memory) {
    return _validators;
  }

  /**
   * @notice Returns the list of registered validator group accounts.
   * @return The list of registered validator group addresses.
   */
  function getRegisteredValidatorGroups() external view returns (address[] memory) {
    return _groups;
  }

  /**
   * @notice Returns whether a particular account has a registered validator group.
   * @param account The account.
   * @return Whether a particular address is a registered validator group.
   */
  function isValidatorGroup(address account) public view returns (bool) {
    return bytes(groups[account].name).length > 0;
  }

  /**
   * @notice Returns whether a particular account has a registered validator.
   * @param account The account.
   * @return Whether a particular address is a registered validator.
   */
  function isValidator(address account) public view returns (bool) {
    return bytes(validators[account].name).length > 0;
  }

  /**
   * @notice Deletes an element from a list of addresses.
   * @param list The list of addresses.
   * @param element The address to delete.
   * @param index The index of `element` in the list.
   */
  function deleteElement(address[] storage list, address element, uint256 index) private {
    require(index < list.length && list[index] == element);
    uint256 lastIndex = list.length.sub(1);
    list[index] = list[lastIndex];
    delete list[lastIndex];
    list.length = lastIndex;
  }

  /**
   * @notice Removes a member from a validator group.
   * @param group The group from which the member should be removed.
   * @param validator The validator to remove from the group.
   * @return True upon success.
   * @dev If `validator` was the only member of `group`, `group` becomes unelectable.
   * @dev Fails if `validator` is not a member of `group`.
   */
  function _removeMember(address group, address validator) private returns (bool) {
    ValidatorGroup storage _group = groups[group];
    require(validators[validator].affiliation == group && _group.members.contains(validator));
    _group.members.remove(validator);
    updateMembershipHistory(validator, address(0));
    emit ValidatorGroupMemberRemoved(group, validator);

    // Empty validator groups are not electable.
    if (groups[group].members.numElements == 0) {
      getElection().markGroupIneligible(group);
    }
    return true;
  }

  function updateMembershipHistory(address account, address group) private returns (bool) {
    MembershipHistory storage history = validators[account].membershipHistory;
    uint256 epochNumber = getEpochNumber();
    if (history.entries.length > 0 && epochNumber == history.entries[history.head].epochNumber) {
      // There have been no elections since the validator last changed membership, overwrite the
      // previous entry.
      history.entries[history.head] = MembershipHistoryEntry(epochNumber, group);
    } else {
      if (history.entries.length > 0) {
        // MembershipHistoryEntries are a circular buffer.
        history.head = history.head.add(1) % membershipHistoryLength;
      }
      if (history.head >= history.entries.length) {
        history.entries.push(MembershipHistoryEntry(epochNumber, group));
      } else {
        history.entries[history.head] = MembershipHistoryEntry(epochNumber, group);
      }
    }
  }

  function getMembershipInLastEpoch(address account) public view returns (address) {
    uint256 epochNumber = getEpochNumber();
    MembershipHistory storage history = validators[account].membershipHistory;
    uint256 head = history.head;
    // If the most recent entry in the membership history is for the current epoch number, we need
    // to look at the previous entry.
    if (history.entries[head].epochNumber == epochNumber) {
      if (head > 0) {
        head = head.sub(1);
      } else if (history.entries.length > 1) {
        head = history.entries.length.sub(1);
      }
    }
    return history.entries[head].group;
  }

  /**
   * @notice De-affiliates a validator, removing it from the group for which it is a member.
   * @param validator The validator to deaffiliate from their affiliated validator group.
   * @param validatorAccount The LockedGold account of the validator.
   * @return True upon success.
   */
  function _deaffiliate(
    Validator storage validator,
    address validatorAccount
  )
    private
    returns (bool)
  {
    address affiliation = validator.affiliation;
    ValidatorGroup storage group = groups[affiliation];
    if (group.members.contains(validatorAccount)) {
      _removeMember(affiliation, validatorAccount);
    }
    emit ValidatorDeaffiliated(validatorAccount, affiliation);
    validator.affiliation = address(0);
    return true;
  }
}
