# Global Sign

Global Sign is a persistent list that carries unfinished problems, to-dos, and plans from your daily notes across days. It is maintained automatically by AI during Smart Generation on the home page, stored in `globalsign.json` in the data directory, and is not cleared when the date changes or the app restarts.

## Content Source

Global Sign content comes from Smart Generation on the home page. On each generation, AI follows the Global Sign prompt from Settings and combines the day's input, the day's daily note content, and the current Global Sign list to return an updated list.

If the columns and daily note are generated but the Global Sign AI update fails, Global Sign keeps its previous content and the page shows a corresponding notice. Global Sign does not modify daily notes or the home columns in return.

## Viewing and Editing

Click the "⋯" button at the right of the home page title bar and choose "Global sign" from the menu to open the Global Sign dialog. When the list is empty, it shows "No content yet".

Each item in the dialog supports the following actions:

- **Edit**: edit the item text directly;
- **Complete / Cancel**: mark the item status, which can be undone before confirming;
- **Delete**: removed immediately after a second confirmation. Deletion is not written to the daily note, does not go through AI organization, and cannot be undone.

After completing, cancelling, or editing items, click "Confirm" to submit the changes. AI then reorganizes the remaining items based on the changes; completed and cancelled items are written into the day's daily note as "Completed:" / "Cancelled:" lines and removed from the list.

If AI is unavailable or the refresh fails, edits are still saved locally, and completed or cancelled items are still removed locally and written to the day's daily note.

## Prompt Settings

The Global Sign prompt can be modified under "Settings > Preferences > Prompts". The prompt can use built-in information such as the current date, the day's daily note content, the current Global Sign JSON, new quick records, and industry. Modifications only affect future Global Sign organization and do not change the saved list content.
