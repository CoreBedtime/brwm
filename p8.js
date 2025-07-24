// --- Configuration ---
const MODIFIERS = getKeyConstants().MOD.CMD | getKeyConstants().MOD.ALT;
const OUTER_PADDING = 85;
const WINDOW_GAP = 55;
const RATIO_STEP = 0.05;
let masterRatio = 0.54;

// --- Layout Logic ---
function adjustMasterRatio(adjustment) {
    const newRatio = masterRatio + adjustment;
    // Keep ratio within reasonable bounds (e.g., 10% to 90%)
    if (newRatio > 0.1 && newRatio < 0.9) {
        masterRatio = newRatio;
        masterStackLayout(); // Retile immediately
    }
}

function masterStackLayout() {
    const screenSize = getScreenSize();
    const windows = getWindows();
    const numWindows = windows.length;
    
    if (numWindows === 0) {
        return;
    }
    
    const availableWidth = screenSize.width - (2 * OUTER_PADDING);
    const availableHeight = screenSize.height - (2 * OUTER_PADDING);
    
    if (numWindows === 1) {
        const [windowInfo] = windows;
        setWindowFrame(windowInfo.wid, OUTER_PADDING, OUTER_PADDING, availableWidth, availableHeight);
        return;
    }
    
    const masterWidth = availableWidth * masterRatio - (WINDOW_GAP / 2);
    const stackWidth = availableWidth * (1 - masterRatio) - (WINDOW_GAP / 2);
    const stackWindowHeight = (availableHeight - ((numWindows - 2) * WINDOW_GAP)) / (numWindows - 1);
    
    // Set frame for the master window
    setWindowFrame(windows[0].wid, OUTER_PADDING, OUTER_PADDING, masterWidth, availableHeight);
    
    // Set frames for the stack windows
    for (let i = 1; i < numWindows; i++) {
        const stackIndex = i - 1;
        const x = OUTER_PADDING + masterWidth + WINDOW_GAP;
        const y = OUTER_PADDING + (stackIndex * (stackWindowHeight + WINDOW_GAP));
        setWindowFrame(windows[i].wid, x, y, stackWidth, stackWindowHeight);
    }
}

// --- Initialization & Keybindings ---
const KEYS = getKeyConstants();

// Wait for spaces API to be ready
while (!spaceList()?.length) {
    sleep(0.1);
}
 
// Bind CMD+ALT+[1-9] to switch spaces
for (let i = 0; i < 9; i++) {
    const keyNum = (i + 1).toString();
    if (KEYS[keyNum]) {
        addKeybind(KEYS[keyNum], MODIFIERS, () => traverseSpace(i));
    }
}

// Bind CMD+ALT+[H/L] to adjust layout
addKeybind(KEYS.L, MODIFIERS, () => adjustMasterRatio(RATIO_STEP));
addKeybind(KEYS.H, MODIFIERS, () => adjustMasterRatio(-RATIO_STEP));

// --- Main Loop ---
while (true) {
    masterStackLayout();
    sleep(2.5);
}
