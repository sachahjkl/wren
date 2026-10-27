type: Fixed

**A click, hover, wheel or focus in an iframe that was not repainted this frame now reaches it** : `frame_under` picks the target from the frame's geometry in the page (its content box, with the page scroll, clips and CSS transforms applied) instead of its paint state, so a frame that is off screen, throttled or simply not repainted in the last chrome frame still takes the pointer and keyboard; off-screen and destroyed frames and frames under a transform are still left alone.
