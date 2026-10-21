GameMemDiag - helps track down "out of memory" crashes in games
==============================================================

It only reads information. It changes nothing on your PC and installs nothing.

SETUP (once)
  1. Right-click the GameMemDiag zip > Properties > tick "Unblock" > OK.
  2. Extract it anywhere, e.g. your Desktop.

EACH TIME YOU PLAY (until the crash happens again)
  1. Double-click Run-GameMemDiag.bat and press 1.
  2. Leave that black window open (minimise it) and play as normal.
  3. When the game crashes, go back to the window and press Q.
  4. Wait about a minute. A zip called GameMemDiag_<PC name>_<date>.zip
     appears on your Desktop. Send that zip back.

IF THE PC FROZE, REBOOTED, OR YOU CLOSED THE WINDOW
  Double-click Run-GameMemDiag.bat and press 2. Everything recorded so far is
  saved as it goes, so nothing is lost. Send the zip it makes.

WHAT'S IN THE ZIP
  Memory and graphics-memory readings taken every 5 seconds, the list of
  programs using the most memory, Windows crash/error events from the last 7
  days, the game's own log and crash files, and a DxDiag. It includes your PC
  name and the names of running programs. It does not include passwords,
  browsing history or personal files.

Monitoring uses almost no CPU and won't affect frame rate.
