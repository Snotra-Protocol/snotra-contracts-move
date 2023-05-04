module snotra_sui::nft_staking {
  
  use sui::clock::{Self, Clock};
  // use std::string::{Self, String};
  use std::vector;
  use sui::coin::{Self, Coin};
  use sui::balance::{Self, Balance};
  use sui::object::{Self, ID, UID};
  use sui::transfer;
  use sui::tx_context::{Self, TxContext};
  use sui::pay;
  // use sui::ed25519;
  
  use sui::dynamic_object_field as ofield;
  /// Errors
  const EINVALID_OWNER: u64 = 1;
  const EESCROW_ALREADY_INITED: u64 = 2;
  const EINVALID_NFTID_OR_INDEX: u64 = 3;
  const EINVALID_TIME: u64 = 4;
  const EINVALID_INDEX: u64 = 5;
  const EEXCEED_MAX_DAILY_REWARD: u64 = 6;
  const EINVALID_ADMIN: u64 = 7;

  /// Constants
  const SECONDS_PER_DAY: u64 = 24 * 60 * 60;

  struct AdminCap has key {
    id: UID
  }

  struct NftStakeInfo<NftT: key + store> has store {
    nft: NftT,
    stake_time: u64,
    daily_reward: u64
  }
  
  struct UserInfo<NftT: key + store> has key, store {
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
    total_staked_count: u64,
    total_claimed_reward: u64
  }

  fun init(ctx: &mut TxContext) {
    let sender = tx_context::sender(ctx);
    transfer::transfer(AdminCap { id: object::new(ctx) }, sender);
  }

  /// create pool for specified Nft Collection and reward coins
  public entry fun create_pool<RewardCoinT, NftT: key + store>(
    creator_address: address,
    deposit_reward_coin: Coin<RewardCoinT>,
    initial_reward_amt: u64,
    is_rarity: u8,
    daily_reward_per_nft: u64,
    max_daily_reward_per_nft: u64,
    ctx: &mut TxContext, 
  ) {

    let sender = tx_context::sender(ctx);

    let pool = PoolInfo<RewardCoinT, NftT> {
      id: object::new(ctx),
      creator_address,
      reward_coin: balance::zero<RewardCoinT>(),
      daily_reward_per_nft,
      max_daily_reward_per_nft,
      is_rarity,
      total_staked_count: 0,
      total_claimed_reward: 0
    };

    // transfer reward
    let coin_amount = coin::value(&deposit_reward_coin);
    let deposit_reward_balance = coin::into_balance(deposit_reward_coin);
    if (coin_amount > initial_reward_amt) {
      let coins_to_return: Coin<RewardCoinT> = coin::take(&mut deposit_reward_balance, coin_amount - initial_reward_amt, ctx);
      transfer::public_transfer(coins_to_return, sender);
    };
    balance::join(&mut pool.reward_coin, deposit_reward_balance);

    // share pool object
    transfer::share_object(pool);
  }
  
  public entry fun stake_nft<RewardCoinT, NftT: key + store>(
    pool: &mut PoolInfo<RewardCoinT, NftT>,
    nft_obj: NftT,
    daily_reward: u64,
    clock: &Clock,
    ctx: &mut TxContext, 
  ) {
    
    let sender = tx_context::sender(ctx);
    let cur_time = clock::timestamp_ms(clock);
    assert!(daily_reward < pool.max_daily_reward_per_nft, EEXCEED_MAX_DAILY_REWARD);

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

    vector::push_back(&mut user_info.nfts, NftStakeInfo<NftT> {
      nft: nft_obj,
      stake_time: cur_time,
      daily_reward
    });

    // update pool info
    pool.total_staked_count = pool.total_staked_count + 1;
  }

  /// unstake NFT from the pool
  public entry fun unstake_nft<RewardCoinT, NftT: key + store>(
    pool: &mut PoolInfo<RewardCoinT, NftT>,
    nft_id: ID,
    nft_index: u64,
    clock: &Clock,
    ctx: &mut TxContext, 
  ) {
    let sender = tx_context::sender(ctx);
    let cur_time = clock::timestamp_ms(clock);

    assert!(ofield::exists_<address>(&pool.id, sender) == true, EINVALID_OWNER);
  
    // check nft availability and calculate the reward
    let user_info = ofield::borrow_mut<address, UserInfo<NftT>>(&mut pool.id, sender);
    let nft_count = vector::length(&user_info.nfts);
    assert!(nft_index < nft_count, EINVALID_INDEX);

    let nft_info_to_unstake = vector::borrow<NftStakeInfo<NftT>>(&user_info.nfts, nft_index);
    let nft_id_to_unstake = object::id(&nft_info_to_unstake.nft);
    assert!(nft_id_to_unstake == nft_id, EINVALID_NFTID_OR_INDEX);

    // calculate the reward
    let reward = get_reward(nft_info_to_unstake, user_info.last_reward_claim_time, cur_time);
    user_info.pending_reward = user_info.pending_reward + reward;

    // remove the nft from vector
    let nft_info_to_unstake = vector::swap_remove(&mut user_info.nfts, nft_index);
    let NftStakeInfo { nft, stake_time: _, daily_reward: _ } = nft_info_to_unstake;

    // transfer nft to sender
    transfer::public_transfer(nft, sender);

    // update pool info
    pool.total_staked_count = pool.total_staked_count - 1;
  }

  /// calculate reward of staked nft
  /// 1. first case (stake_time < last_reward_time)
  /// ---------------------||----------||----------------------||
  ///               stake_time       last_reward_time         current_time
  /// 2. second case (stake_time > last_reward_time)
  /// ---------------------||----------||----------------------||
  ///              last_reward_time  stake_time               current_time
  fun get_reward<NftT: key + store>(nft_stake_info: &NftStakeInfo<NftT>, last_reward_claim_time: u64, current_time: u64) : u64 {
    assert!(last_reward_claim_time <= current_time, EINVALID_TIME);
    assert!(nft_stake_info.stake_time <= current_time, EINVALID_TIME);

    let calculated_reward: u64;

    // 1. first case
    if (nft_stake_info.stake_time < last_reward_claim_time) {
      let duration = current_time - last_reward_claim_time;
      calculated_reward = duration * nft_stake_info.daily_reward / SECONDS_PER_DAY;
    } else { // 2. second case
      let duration = current_time - nft_stake_info.stake_time;
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
    while (index < nft_count) {
      reward_sum = reward_sum + get_reward<NftT>(vector::borrow(&user_info.nfts, index), user_info.last_reward_claim_time, cur_time);
      index = index + 1;
    };
    reward_sum
  }

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
  }

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

  public entry fun change_admin<RewardCoinT, NftT: key + store>(
    admin_cap: AdminCap,
    new_admin: address,
    _ctx: &mut TxContext, 
  ){
    transfer::transfer(admin_cap, new_admin);
  }

  #[test_only]
  public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
  }

  #[test_only]
  public fun get_pool_id<CoinT, NftT>(obj: &PoolInfo<CoinT, NftT>): &UID {
    &obj.id
  }
}