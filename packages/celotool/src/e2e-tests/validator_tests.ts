import { assert } from 'chai'
import { getHooks, sleep } from './validator_utils'

describe('sentry tests', function(this: any) {
  this.timeout(0)

  const gethConfig = {
    migrate: false,
    networkId: 1101,
    networkName: 'berlintestnet001',
    downloadGenesis: true,
    instances: [
      {
        name: 'validator0',
        validating: true,
        syncmode: 'full',
        port: 30303,
        rpcport: 8545,
        isProxied: true,
        sentry: 'sentry0',
        ethstats:
          'berlintestnet001-tx-nodes-0:BpY78yZRZIHeb1iobaL9DZvu@berlintestnet001-ethstats.celo-networks-dev.org',
      },
      {
        name: 'sentry0',
        validating: false,
        syncmode: 'full',
        port: 30304,
        sentryport: 30305,
        rpcport: 8546,
        isSentry: true,
        ethstats:
          'berlintestnet001-tx-nodes-0:BpY78yZRZIHeb1iobaL9DZvu@berlintestnet001-ethstats.celo-networks-dev.org',
      },
    ],
    useBootnode: true,
  }
  const hooks = getHooks(gethConfig)

  before(async () => {
    // Start validator nodes and migrate contracts.
    await hooks.before()
    // Restart validator nodes.
    await hooks.restart()
    // Give validators time to connect to eachother.
    await sleep(60)
  })

  it('dummy test', async () => {
    assert.fail('test')
  })
})
