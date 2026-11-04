type: Fixed

**An `unclean exit` note now means one:** a crash that wrote its report and a close ended by the shutdown watchdog (it has `shutdown.log`) no longer leave one too at the next start (15 of the 43 notes of a real profile were the crash already reported).
