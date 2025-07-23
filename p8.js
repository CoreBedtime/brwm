const screenSize = getScreenSize();

function masterStackLayout() {
    const windows = getWindows();
    const numWindows = windows.length;
    
    if (numWindows === 0) {
        return;
    }
    
    const outerPadding = 100;
    const windowGap = 20;
    const masterRatio = 0.64;
    
    const availableWidth = screenSize.width - (2 * outerPadding);
    const availableHeight = screenSize.height - (2 * outerPadding);
    
    if (numWindows === 1) {
        const windowInfo = windows[0];
        setWindowFrame(
            windowInfo.wid,
            outerPadding,
            outerPadding,
            availableWidth,
            availableHeight
        );
        return;
    }
    
    const masterWidth = availableWidth * masterRatio - (windowGap / 2);
    const stackWidth = availableWidth * (1 - masterRatio) - (windowGap / 2);
    const stackWindowHeight = (availableHeight - ((numWindows - 2) * windowGap)) / (numWindows - 1);
    
    for (let i = 0; i < numWindows; i++) {
        const windowInfo = windows[i];
        const windowId = windowInfo.wid;
        
        if (i === 0) {
            setWindowFrame(
                windowId,
                outerPadding,
                outerPadding,
                masterWidth,
                availableHeight
            );
        } else {
            const stackIndex = i - 1;
            const x = outerPadding + masterWidth + windowGap;
            const y = outerPadding + (stackIndex * (stackWindowHeight + windowGap));
            
            setWindowFrame(
                windowId,
                x,
                y,
                stackWidth,
                stackWindowHeight
            );
        }
    }
}

while (true) {
    masterStackLayout();
    sleep(2.5);
    
    try {
        pokeSpace();
    } catch (error) {
        // Handle errors gracefully, log them or ignore
    }
}
