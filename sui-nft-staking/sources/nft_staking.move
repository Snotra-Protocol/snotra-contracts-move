module snotra_sui::nft_staking {
  
  use std::ascii;
  use std::vector;
  use std::type_name;

  use sui::clock::{Self, Clock};
  use sui::coin::{Self, Coin};
  use sui::balance::{Self, Balance};
  use sui::object::{Self, ID, UID};
  use sui::transfer;
  use sui::tx_context::{Self, TxContext};
  use sui::pay;
  use sui::ed25519;
  use sui::event;
  use sui::dynamic_object_field as ofield;
  use sui::sui::SUI;
  use sui::package;

  use sui::kiosk::{Self, Kiosk, KioskOwnerCap, PurchaseCap};
  use sui::transfer_policy::{Self as policy, TransferPolicy, TransferPolicyCap};


  /// Errors
  const EINVALID_OWNER: u64 = 1;
  const EESCROW_ALREADY_INITED: u64 = 2;
  const EINVALID_NFTID_OR_INDEX: u64 = 3;
  const EINVALID_TIME: u64 = 4;
  const EINVALID_INDEX: u64 = 5;
  const EEXCEED_MAX_DAILY_REWARD: u64 = 6;
  const EINVALID_ADMIN: u64 = 7;
  const EINVALID_DAILY_REWARD: u64 = 8;
  const EINVALID_SIGNATURE: u64 = 9;
  const ESTILL_LOCKED: u64 = 10;
  const EPOOL_ENDED: u64 = 11;
  const EINSUFFICIENT_FEE_AMOUNT: u64 = 12;
  const ENFT_EMPTY: u64 = 12;
  const EKIOSK_ALREADY_LOCKED: u64 = 12;

  /// Constants
  const SECONDS_PER_DAY: u64 = 24 * 60 * 60;

  /// Objects
  struct NFT_STAKING has drop {}
  struct AdminCap has key {
    id: UID,
  }

  struct PlatformInfo has key {
    id: UID,
    platform_fee: Balance<SUI>,
    sig_verify_pk: vector<u8>,
    publisher: package::Publisher
  }

  struct NftStakeInfo<phantom NftT: key + store> has store {
    nft_kiosk: Kiosk,
    nft_kiosk_cap: KioskOwnerCap,
    policy: TransferPolicy<NftT>,
    policy_cap: TransferPolicyCap<NftT>,
    purchase_cap: PurchaseCap<NftT>,
    stake_time: u64,
    daily_reward: u64
  }
  
  struct UserInfo<phantom NftT: key + store> has key, store {
    id: UID,
    owner_address: address,
    last_reward_claim_time: u64,
    pending_reward: u64,
    nfts: vector<NftStakeInfo<NftT>>,
  }

  struct PoolInfo<phantom CoinT, phantom NftT> has key {
    id: UID,
    creator_address: address,
    reward_coin: Balance<CoinT>,
    // daily reward per nft
    daily_reward_per_nft: u64,
    max_daily_reward_per_nft: u64,
    is_rarity: u8,
    creation_time: u64,
    lock_duration: u64, // 0: flexible, otherwise: duration
    stake_nonce: u64,
    total_staked_count: u64,
    total_claimed_reward: u64
  }

  /// events
  struct PoolCreated has copy, drop {
    pool_id: ID,
    creator: address,
    nft_type: ascii::String,
    reward_coin_type: ascii::String,
    is_rarity: u8,
    creation_time: u64,
    lock_duration: u64,
    daily_reward_per_nft: u64,
    max_daily_reward_per_nft: u64,
    initial_reward_amt: u64,
  }

  struct NftStaked has copy, drop {
    nft_id: ID,
    pool_id: ID,
    owner: address,
    nft_type: ascii::String,
    reward_coin_type: ascii::String,
    daily_reward: u64,
  }

  struct NftUnStaked has copy, drop {
    nft_id: ID,
    pool_id: ID,
    owner: address,
    nft_type: ascii::String,
    reward_coin_type: ascii::String
  }

  struct ClaimedReward has copy, drop {
    owner: address,
    pool_id: ID,
    claimed_amount: u64,
  }

  fun init(witness: NFT_STAKING, ctx: &mut TxContext) {
    let sender = tx_context::sender(ctx);
    let publisher = package::claim(witness, ctx);

    transfer::transfer(AdminCap { id: object::new(ctx) }, sender);
    transfer::share_object(
      PlatformInfo {
        id: object::new(ctx),
        sig_verify_pk: vector::empty<u8>(),
        platform_fee: balance::zero<SUI>(),
        publisher
      }
    );
  }

  /// create pool for specified Nft Collection and reward coins
  public entry fun create_pool<RewardCoinT, NftT: key + store>(
    _admin_cap: &AdminCap,
    creator_address: address,
    deposit_reward_coin: Coin<RewardCoinT>,
    initial_reward_amt: u64,
    is_rarity: u8,
    lock_duration: u64,
    daily_reward_per_nft: u64,
    max_daily_reward_per_nft: u64,
    clock: &Clock,
    ctx: &mut TxContext, 
  ) {

    let cur_time = clock::timestamp_ms(clock);
    let sender = tx_context::sender(ctx);

    let pool = PoolInfo<RewardCoinT, NftT> {
      id: object::new(ctx),
      creator_address,
      reward_coin: balance::zero<RewardCoinT>(),
      daily_reward_per_nft,
      max_daily_reward_per_nft,
      is_rarity,
      creation_time: cur_time,
      lock_duration,
      total_staked_count: 0,
      total_claimed_reward: 0,
      stake_nonce: 0
    };

    // transfer reward
    let coin_amount = coin::value(&deposit_reward_coin);
    let deposit_reward_balance = coin::into_balance(deposit_reward_coin);
    if (coin_amount > initial_reward_amt) {
      let coins_to_return: Coin<RewardCoinT> = coin::take(&mut deposit_reward_balance, coin_amount - initial_reward_amt, ctx);
      transfer::public_transfer(coins_to_return, sender);
    };
    balance::join(&mut pool.reward_coin, deposit_reward_balance);

    // event
    event::emit(PoolCreated {
      pool_id: object::id(&pool),
      creator: sender,
      nft_type: *type_name::borrow_string(&type_name::get<NftT>()),
      reward_coin_type: *type_name::borrow_string(&type_name::get<RewardCoinT>()),
      is_rarity,
      creation_time: cur_time,
      lock_duration,
      daily_reward_per_nft,
      max_daily_reward_per_nft,
      initial_reward_amt,
    });

    // share pool object
    transfer::share_object(pool);
  }
  
  /// function to verify daily_reward signature
  public fun verify_signature(main_value: u64, nonce_value: u64, verify_pk: vector<u8>, signature: vector<u8>): bool {
    let sign_data = std::bcs::to_bytes(&main_value);
    let nonce_bytes = std::bcs::to_bytes(&nonce_value);
    vector::append(&mut sign_data, nonce_bytes);

    std::debug::print<vector<u8>>(&sign_data);

    let verify = ed25519::ed25519_verify(
      &signature, 
      &verify_pk, 
      &sign_data
    );
    verify
  }

  public entry fun stake_kiosk<RewardCoinT, NftT: key + store>(
    _platform: &mut PlatformInfo,
    _pool: &mut PoolInfo<RewardCoinT, NftT>,
    nft_kiosk: &mut Kiosk,
    nft_kiosk_ownercap: &KioskOwnerCap,
    nft_id: ID,
    _daily_reward: u64,
    _daily_reward_signature: vector<u8>,
    _sui_fee: Coin<SUI>,
    _stake_fee_amount: u64,
    _stake_fee_amount_signature: vector<u8>,
    _clock: &Clock,
    _ctx: &mut TxContext,
  ) {
    let nft_obj = kiosk::take(nft_kiosk, nft_kiosk_ownercap, nft_id);
    stake_nft(
      _platform,
      _pool,
      nft_obj,
      _daily_reward,
      _daily_reward_signature,
      _sui_fee,
      _stake_fee_amount,
      _stake_fee_amount_signature,
      _clock,
      _ctx
    );
  }


  /// staker stake nft
  public entry fun stake_nft<RewardCoinT, NftT: key + store>(
    platform: &mut PlatformInfo,
    pool: &mut PoolInfo<RewardCoinT, NftT>,
    nft_obj: NftT,
    daily_reward: u64,
    daily_reward_signature: vector<u8>,
    sui_fee: Coin<SUI>,
    stake_fee_amount: u64,
    stake_fee_amount_signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext, 
  ) {
    
    let sender = tx_context::sender(ctx);
    let cur_time = clock::timestamp_ms(clock);

    // if duration is not flexible
    if (pool.lock_duration > 0) {
      assert!(pool.creation_time + pool.lock_duration > cur_time, EPOOL_ENDED);
    };

    assert!(daily_reward < pool.max_daily_reward_per_nft, EEXCEED_MAX_DAILY_REWARD);
    assert!(verify_signature(daily_reward, pool.stake_nonce, platform.sig_verify_pk, daily_reward_signature) == true, EINVALID_SIGNATURE);

    // check daily reward
    if (pool.is_rarity == 0) {
      assert!(daily_reward == pool.daily_reward_per_nft, EINVALID_DAILY_REWARD);
    };

    // verify fee_amount
    assert!(verify_signature(stake_fee_amount, pool.stake_nonce, platform.sig_verify_pk, stake_fee_amount_signature) == true, EINVALID_SIGNATURE);

    // cut stake fee
    if (stake_fee_amount > 0) {
      let obj_sui_amount = coin::value(&sui_fee);
      let fee_balance_obj = coin::into_balance(sui_fee);
      
      assert!(obj_sui_amount >= stake_fee_amount, EINSUFFICIENT_FEE_AMOUNT);
      
      if (obj_sui_amount > stake_fee_amount) {
        // if fee coin object is bigger than stake_fee_amount, please return rest of the money to the sender
        let coins_to_return: Coin<SUI> = coin::take(&mut fee_balance_obj, obj_sui_amount - stake_fee_amount, ctx);
        pay::keep(coins_to_return, ctx);
      };

      balance::join(&mut platform.platform_fee, fee_balance_obj);
    } else {
      // should return sui coin
      pay::keep(sui_fee, ctx);
    };

    // check if sender is already a staker
    if (!ofield::exists_<address>(&pool.id, sender)) {
      ofield::add(&mut pool.id, sender, UserInfo<NftT> {
        id: object::new(ctx),
        owner_address: sender,
        last_reward_claim_time: cur_time,
        pending_reward: 0,
        nfts: vector::empty<NftStakeInfo<NftT>>()
      });
    };

    let user_info = ofield::borrow_mut<address, UserInfo<NftT>>(&mut pool.id, sender);

    // create a kiosk

    let (policy, policy_cap) = get_policy<NftT>(platform, ctx);
    let (new_kiosk, new_kiosk_cap) = kiosk::new(ctx);
    let nft_id = object::id(&nft_obj);
    kiosk::place(&mut new_kiosk, &new_kiosk_cap, nft_obj);
    let purchase_cap = kiosk::list_with_purchase_cap<NftT>(&mut new_kiosk, &new_kiosk_cap, nft_id, 0, ctx);

    vector::push_back(&mut user_info.nfts, NftStakeInfo<NftT> {
      nft_kiosk: new_kiosk,
      nft_kiosk_cap: new_kiosk_cap,
      policy,
      policy_cap,
      purchase_cap,
      stake_time: cur_time,
      daily_reward
    });

    // update pool info
    pool.total_staked_count = pool.total_staked_count + 1;
    pool.stake_nonce = pool.stake_nonce + 1;

    // emit event
    event::emit(NftStaked {
      nft_id,
      pool_id: object::id(pool),
      owner: sender,
      nft_type: *type_name::borrow_string(&type_name::get<NftT>()),
      reward_coin_type: *type_name::borrow_string(&type_name::get<RewardCoinT>()),
      daily_reward
    });
  }

  /// unstake NFT from the pool
  public entry fun unstake_nft<RewardCoinT, NftT: key + store>(
    platform: &mut PlatformInfo,
    pool: &mut PoolInfo<RewardCoinT, NftT>,
    nft_id: ID,
    nft_index: u64,
    sui_fee: Coin<SUI>,
    stake_fee_amount: u64,
    stake_fee_amount_signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext, 
  ) {
    let sender = tx_context::sender(ctx);
    let cur_time = clock::timestamp_ms(clock);

    assert!(ofield::exists_<address>(&pool.id, sender) == true, EINVALID_OWNER);

    // lock duration check
    let pool_end_time: u64 = 0;
    
    // if duration is not flexible
    if (pool.lock_duration > 0) {
      pool_end_time = pool.creation_time + pool.lock_duration;
      assert!(pool_end_time <= cur_time, ESTILL_LOCKED);
    };

    // verify fee_amount
    assert!(verify_signature(stake_fee_amount, pool.stake_nonce, platform.sig_verify_pk, stake_fee_amount_signature) == true, EINVALID_SIGNATURE);

    // cut stake fee
    if (stake_fee_amount > 0) {
      let obj_sui_amount = coin::value(&sui_fee);
      let fee_balance_obj = coin::into_balance(sui_fee);
      
      assert!(obj_sui_amount >= stake_fee_amount, EINSUFFICIENT_FEE_AMOUNT);
      
      if (obj_sui_amount > stake_fee_amount) {
        // if fee coin object is bigger than stake_fee_amount, please return rest of the money to the sender
        let coins_to_return: Coin<SUI> = coin::take(&mut fee_balance_obj, obj_sui_amount - stake_fee_amount, ctx);
        pay::keep(coins_to_return, ctx);
      };

      balance::join(&mut platform.platform_fee, fee_balance_obj);
    } else {
      // should return sui coin
      pay::keep(sui_fee, ctx);
    };

    // check nft availability and calculate the reward
    let user_info = ofield::borrow_mut<address, UserInfo<NftT>>(&mut pool.id, sender);
    let nft_count = vector::length(&user_info.nfts);
    assert!(nft_index < nft_count, EINVALID_INDEX);

    let nft_info_to_unstake = vector::borrow<NftStakeInfo<NftT>>(&user_info.nfts, nft_index);

    // calculate the reward
    let reward = get_reward(nft_info_to_unstake, user_info.last_reward_claim_time, cur_time, pool_end_time);
    user_info.pending_reward = user_info.pending_reward + reward;

    // remove the nft from vector
    let nft_info_to_unstake = vector::swap_remove(&mut user_info.nfts, nft_index);

    let NftStakeInfo { 
      nft_kiosk, 
      nft_kiosk_cap, 
      policy,
      policy_cap,
      purchase_cap,
      stake_time: _, 
      daily_reward: _ 
    } = nft_info_to_unstake;

    let (nft, request) = kiosk::purchase_with_cap(&mut nft_kiosk, purchase_cap, coin::zero<SUI>(ctx));
    policy::confirm_request(&mut policy, request);

    // check nft_id
    assert!(object::id(&nft) == nft_id, EINVALID_NFTID_OR_INDEX);

    // update pool info
    pool.total_staked_count = pool.total_staked_count - 1;
    pool.stake_nonce = pool.stake_nonce + 1;

    // emit event
    event::emit(NftUnStaked {
      nft_id: object::id(&nft),
      pool_id: object::id(pool),
      owner: sender,
      nft_type: *type_name::borrow_string(&type_name::get<NftT>()),
      reward_coin_type: *type_name::borrow_string(&type_name::get<RewardCoinT>())
    });

    // transfer nft to sender
    transfer::public_transfer(nft, sender);

    // close kiosk
    let sui_coin = kiosk::close_and_withdraw(nft_kiosk, nft_kiosk_cap, ctx);
    coin::destroy_zero(sui_coin);
    let profits = policy::destroy_and_withdraw(policy, policy_cap, ctx);
    coin::destroy_zero(profits);
  }

  /// calculate reward of staked nft
  /// 1. first case (stake_time < last_reward_time)
  /// ---------------------||----------||----------------------||
  ///               stake_time       last_reward_time         current_time
  /// 2. second case (stake_time > last_reward_time)
  /// ---------------------||----------||----------------------||
  ///              last_reward_time  stake_time               current_time
  fun get_reward<NftT: key + store>(nft_stake_info: &NftStakeInfo<NftT>, last_reward_claim_time: u64, current_time: u64, pool_end_time: u64) : u64 {
    let base_time = current_time;
    // not flexible but the pool is ended at the moment
    if (pool_end_time > 0 && current_time > pool_end_time)
      base_time = pool_end_time;

    // this is invalid case
    assert!(nft_stake_info.stake_time <= base_time, EINVALID_TIME);

    if (last_reward_claim_time > base_time) return 0;

    let calculated_reward: u64;

    // 1. first case
    if (nft_stake_info.stake_time < last_reward_claim_time) {
      let duration = base_time - last_reward_claim_time;
      calculated_reward = duration * nft_stake_info.daily_reward / SECONDS_PER_DAY;
    } else { // 2. second case
      let duration = base_time - nft_stake_info.stake_time;
      calculated_reward = duration * nft_stake_info.daily_reward / SECONDS_PER_DAY;
    };

    calculated_reward
  }

  /// view function
  public fun calculate_rewards<RewardCoinT, NftT: key + store>(pool: &PoolInfo<RewardCoinT, NftT>, sender: address, clock: &Clock): u64 {
    let cur_time = clock::timestamp_ms(clock);
    let user_info = ofield::borrow<address, UserInfo<NftT>>(&pool.id, sender);
    let nft_count = vector::length(&user_info.nfts);
    let index = 0;
    let reward_sum = user_info.pending_reward;

    let pool_end_time: u64 = 0;
    if (pool.lock_duration > 0) {
      pool_end_time = pool.creation_time + pool.lock_duration;
    };

    while (index < nft_count) {
      reward_sum = reward_sum + get_reward<NftT>(vector::borrow(&user_info.nfts, index), user_info.last_reward_claim_time, cur_time, pool_end_time);
      index = index + 1;
    };
    reward_sum
  }

  /// staker claim rewards
  public entry fun claim_reward<RewardCoinT, NftT: key + store>(
    pool: &mut PoolInfo<RewardCoinT, NftT>,
    clock: &Clock,
    ctx: &mut TxContext, 
  ){
    let sender = tx_context::sender(ctx);
    let cur_time = clock::timestamp_ms(clock);

    assert!(ofield::exists_<address>(&pool.id, sender) == true, EINVALID_OWNER);
  
    // check nft availability and calculate the reward
    let reward_sum = calculate_rewards(pool, sender, clock);
    let user_info = ofield::borrow_mut<address, UserInfo<NftT>>(&mut pool.id, sender);

    // transfer reward_coin to claimer
    let total_reward_amount = balance::value(&pool.reward_coin);
    if (reward_sum > total_reward_amount) reward_sum = total_reward_amount;
    let reward_to_claim: Coin<RewardCoinT> = coin::take(&mut pool.reward_coin, reward_sum, ctx);
    
    pay::keep(reward_to_claim, ctx);

    // update user info
    user_info.pending_reward = 0;
    user_info.last_reward_claim_time = cur_time;

    // update pool info
    pool.total_claimed_reward = pool.total_claimed_reward + reward_sum;
    
    // emit event
    event::emit(ClaimedReward {
      owner: sender,
      pool_id: object::id(pool),
      claimed_amount: reward_sum
    });
  }

  /// admin can withdraw remained reward from the pool
  public entry fun withdraw_reward<RewardCoinT, NftT: key + store>(
    _admin_cap: &AdminCap,
    pool: &mut PoolInfo<RewardCoinT, NftT>,
    ctx: &mut TxContext, 
  ){
    // transfer reward_coin to claimer
    let total_reward_amount = balance::value(&pool.reward_coin);
    let reward_to_withdraw: Coin<RewardCoinT> = coin::take(&mut pool.reward_coin, total_reward_amount, ctx);
    pay::keep(reward_to_withdraw, ctx);
  }

  /// admin can transfer ownership to new admin
  public entry fun change_admin(
    admin_cap: AdminCap,
    new_admin: address,
    _ctx: &mut TxContext, 
  ){
    transfer::transfer(admin_cap, new_admin);
  }

  /// admin can change the public key of SingatureMaker
  public entry fun change_verify_pk(
    platform: &mut PlatformInfo,
    _admin_cap: &AdminCap,
    new_verify_pk: vector<u8>,
    _ctx: &mut TxContext, 
  ){
    platform.sig_verify_pk = new_verify_pk;
  }

  /// admin can withdraw remained reward from the pool
  public entry fun withdraw_platform_fee(
    platform: &mut PlatformInfo,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext, 
  ){
    // transfer reward_coin to claimer
    let accumulated_fee_amount = balance::value(&platform.platform_fee);
    let fee_to_withdraw: Coin<SUI> = coin::take(&mut platform.platform_fee, accumulated_fee_amount, ctx);
    pay::keep(fee_to_withdraw, ctx);
  }

  public fun get_policy<T>(platform: &PlatformInfo, ctx: &mut TxContext): (TransferPolicy<T>, TransferPolicyCap<T>) {
      let (policy, cap) = policy::new(&platform.publisher, ctx);
      (policy, cap)
  }


  #[test_only]
  public fun init_for_testing(ctx: &mut TxContext) {
    init(NFT_STAKING {}, ctx)
  }

  #[test_only]
  public fun get_pool_id<CoinT, NftT>(obj: &PoolInfo<CoinT, NftT>): &UID {
    &obj.id
  }
}