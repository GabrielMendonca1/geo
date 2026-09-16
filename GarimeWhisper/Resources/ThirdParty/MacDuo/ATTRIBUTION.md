# Attribution

Thanks to Sam Henri Gold for publicly documenting and demonstrating the MacBook lid-angle sensor in [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor), published under Apache License 2.0.

Mac Duo's reader was written for this project. Its device identifiers (Sensor page 0x20, Orientation usage 0x8A), feature-report ID 1, and two-byte little-endian degree value were verified against that project and against this M4 MacBook Pro's hardware. No audio or other assets from that project are included.

The animation and controls are original. Bendy and the public demonstrations by Adrian Abelarde and Seb Vidal are visual and architectural references, not dependencies. This project is not affiliated with those developers or Apple.

## Effect study for 0.1.2

The user's supplied Bendy demonstration video was studied alongside [FrostFold](https://github.com/askmaddyy/FrostFold/tree/a9af51a5565b7d75525c7aab84f2add96d0669ae) (MIT) and [iphone-solo](https://github.com/soloiaros/iphone-solo/tree/752764bdf68ca16d55b65c76738c23d4266b1137) (no license file present in the studied tree). They informed the discussion of stationary content, tilted glass, and multiscale defocus. Their source, graphics, and videos are not bundled in the app or the source distribution. The shipped Metal implementation is original, with a bottom-anchored expansion and a binomial blur pyramid, developed after an independent Claude Opus 5 review.

These projects are independent recreations. They do not establish how Apple implemented its animation. Mac Duo aims for its own responsive visual treatment rather than a claim of pixel-identical reproduction.
