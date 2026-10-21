# Stable browser: manual visual checks

Relaunch the original test game to load the final Lua/menu update. The running
original session was left in its dialogue, so it still has the earlier code.
The separate buffbot-stable-review-profile window is an earlier review process.

1. Start a fresh preset. Death Ward should show 15–20m before selecting Keldorn.
   Assigning him should update uses and his duration without moving the row.
2. Reserve all four uses. All eligible portraits should stay visible, with a
   subtle warning beside 0/4. Clicking a fifth recipient should add nothing.
   Unselect one recipient, then select another: the swap should work.
3. Click a duration header to re-sort. Assign/unassign buffs: row positions should
   stay stable. Reopen or explicitly refresh/sort to apply a new order.
4. Open and repeat-click the gear, preset and After rest triggers. Each should
   close its own dropdown. Blank space should neither dismiss the UI nor issue
   movement orders to the game behind it.
5. Check that the rectangle beyond the decorative frame is gone and that all
   pages/popups still have readable backgrounds.

Automated allocation/presentation coverage is recorded in review.md. Final visual
confirmation of this follow-up is pending the user's testing.
