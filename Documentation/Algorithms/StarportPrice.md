# Starport CHOAM price (and the order charge)

Reference: `GUI_FactoryWindow_CalculateStarportPrice` (`src/gui/gui.c:2726`), the factory-window price fill (`gui.c:2769`), and the order charge (`src/gui/widget_click.c:1308`) + refund (`:1113`).

When the player opens the **starport** factory window, each in-stock unit is priced through CHOAM — a randomised discount/markup on the unit's base build cost, **not** the build-yard price. The price is rolled once per window open and charged when the order is sent.

## The formula

```
price = (c/10)*4 + (c/10)*(RandomLCG_Range(0,6) + RandomLCG_Range(0,6))
price = min(price, 999)
```

where `c` is the unit's `UnitInfo.buildCredits`. Integer division (`c/10`) throughout. The base term `(c/10)*4` is 40% of the cost; the two `RandomLCG_Range(0,6)` draws add 0…12 tenths, so the roll spans **40%…160%** of the base cost, capped at 999. It draws **two `RandomLCG` values per item** in order.

Ported as `GameState.starportPrice(buildCredits:)` (a `mutating` method — it draws the LCG). Because it consumes RNG, opening the starport list perturbs the LCG stream exactly as the original does; this is faithful and only matters interactively (the headless scenario goldens never open a window).

## The order charge

`Structure_BuildObject`'s `FACTORY_BUY` body (our `UnitCombat.structureStarportOrder`) is the EMC native: it creates the unit off-map, chains it onto the house delivery list, and decrements `g_starportAvailable`. It does **not** itself touch credits — in OpenDUNE the GUI charges `h->credits -= amount` on send and refunds on a pool-full failure. We fold that into `structureStarportOrder(…, price:)`: it deducts `price` up front and **refunds it** if the unit can't be allocated (pool full). `price` defaults to `0` (the EMC-only behaviour, so existing callers/goldens are unchanged); the duneii client passes the rolled CHOAM price.

## duneii wiring

When a starport becomes the selected structure, `GameModel` rolls a CHOAM price for every in-stock unit **once** (guarded on the selected-starport slot so it doesn't re-roll every tick), shows them in the order list, greys out the unaffordable ones, and on click issues `Command.starportOrder(structure:objectType:price:)` — charging the player. See `Architecture/DuneiiClient.md`.

## Parity / determinism

Default off-path (`price == 0`) is byte-identical, so the starport-order golden and the rest of the suite are unchanged. The price formula itself is covered cross-engine by the **`starport-price`** golden: the oracle harness's `--parity-starport-price=<c-list>` seeds `RandomLCG(0)` and dumps `GUI_FactoryWindow_CalculateStarportPrice` for each `c`; `StarportPriceTests` seeds our `randomLCG(0)` and matches the dump value-for-value (proving the formula + the two-draw order align with the oracle).
