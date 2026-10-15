# MTRX3700 Major Project — FPGA Autonomous Multi-Bay Parking

**Group 26 · Semester 2, 2026 · University of Sydney**  
**Project status:** Planning / staged implementation  
**Primary delivery target:** V4 hardware-verified by **Tuesday 27 October 2026**  
**Optional extension target:** V5 hardware-verified in **Thursday 29 October 2026 (Week 12 lab)**  
**Demonstration:** Thursday 5 November 2026 · **Video:** Wednesday 4 November 11:59 pm · **Report/code:** Sunday 8 November 11:59 pm

> **Scope and attribution notice:** This README specifies the proposed architecture, development milestones, and planned files. It does not assert that any listed RTL block already exists or has passed testing. Existing file names, ports and interfaces from Assignment 1, Assignment 2, Ed Lessons 3–5, and the Major Project Resources must be checked against the actual source before importing. Record every source file's **owner SID, origin and modifications** in `OWNERS.md`. Staff-provided code can be reused but does not itself qualify as an original contribution.

## 1. Overview

Build an FPGA-controlled mobile robot using the **DE1-SoC Cyclone V**, **UGV02 differential-drive chassis**, **OV7670 camera**, **RCWL-1601 ultrasonic ranging**, and **IR remote**. The robot observes three fixed parking targets, identifies the **currently illuminated bay**, aligns and approaches using live camera data, parks at a safe stand-off distance, reverses into a useful viewing position, and acquires the next illuminated bay.

The main technical challenge is **reliable visual acquisition and reacquisition during repeated autonomous parking**, despite variable lighting, visual distractions, changing camera field of view, wheel drift and imperfect open-loop reversing.

The project deliberately avoids full geometric pose estimation, general visual odometry and SLAM on the critical path. Its main advanced capability is a **visibility-aware repositioning controller** supported by persistent visual references near each bay. This is an **HD candidate, not a guaranteed grade**: the project must demonstrate a new capability beyond provided code or routine combinations, verified by meaningful on-board hardware comparisons.

### Intended physical setup

- Three stationary bay targets visible across a shared test arena. Each has an **individually controllable light** and a **permanent, high-contrast reference marker** (visible even when the LED is off).
- DE1-SoC and sensors mounted on the moving UGV02; camera faces the docking targets.
- The **FPGA** processes camera pixels, estimates target/image geometry, generates motion decisions and owns safety-critical stop decisions.
- A **stationary ESP32 or equivalent** may act only as an LED-output peripheral, if approved. The FPGA may select/sequence target lights via a permitted relay; a manually advanced target board is the development fallback. Neither peripheral does camera processing or navigation.
- The **Arduino Nano 33 IoT** remains a permitted communications relay only, subject to validating the actual adapter and firmware interfaces.
- Reverse motion is allowed **only in a physically cleared, bounded corridor**; a forward-facing ultrasonic sensor is not rear-obstacle protection.

### Closed-loop sequence

`WAIT / SELECT_TARGET → SEARCH → ALIGN → APPROACH → PARKED → REVERSE → REACQUIRE → SEARCH …`

At any point, `IR_ESTOP`, invalid critical sensing, an expired reverse limit, or unsafe actuation state overrides movement. The camera must genuinely observe each commanded active target; knowing which LED the FPGA requested is **not** a substitute for camera-based detection.

## 2. Mandatory brief requirements (release checklist)

| ID | Requirement and planned evidence |
|---|---|
| **R1** | Live OV7670 pixels processed **on DE1-SoC** must influence real movement. Show camera-to-wheel closed-loop proof. |
| **R2** | FPGA controls direction, turning and variable wheel speed through chassis UART. |
| **R3** | Latched IR emergency stop works from every robot state and takes priority before any driving test. |
| **R4** | Sensor processing and motion decisions on DE1-SoC; Nano/extra boards only perform approved relay/peripheral duties. |
| **R5** | **3–5 numeric targets**, including timing and accuracy/repeatability; define units, test conditions/ranges, thresholds, goals and three-trial scoring rules. |
| **R6** | Self-checking Verilator **5.050** `run_all_tests.sh`, module **and system** tests, injected faults visibly `CAUGHT`, completes **under five minutes**. |
| **R7** | Golden-model versus RTL output comparisons using **recorded real hardware inputs**. |
| **R8** | Each member owns a **new or substantively adapted synthesizable module** and testbench; every source listed with SID/ownership/origin in `OWNERS.md`. |
| **R9** | Physical DE1-SoC switch bypasses major custom processing while keeping the robot operating; demonstrate measurable degradation versus custom enabled mode. |

**Course level interpretation:** V1 aims at Pass functionality; V2 at a Credit candidate; V3 at a Distinction candidate; V4 at an HD candidate. These labels represent planned evidence, **not grades awarded for reaching a filename or feature count**. The tutor determines the highest level actually demonstrated.

## 3. Architecture and owners

```text
                  ┌─────────────────────────────────────┐
 OV7670 pixels ──>│ M1 — CAMERA & PREPROCESSING (Luke) │
                  │ capture / pixel format / filtering   │
                  └────────────────┬────────────────────┘
                                   │ frame-aligned pixels/features
                  ┌────────────────▼────────────────────┐
                  │ M2 — PERCEPTION & TRACKING (Marcus) │
                  │ target location / stability / view  │
                  └────────────────┬────────────────────┘
                                   │ target + viewing observations
                  ┌────────────────▼────────────────────┐
                  │ M3 — PARKING & REPOSITION (Jason)   │
                  │ parking FSM / control / return path  │
                  └────────────────┬────────────────────┘
                                   │ wheel requests + target ID
                  ┌────────────────▼────────────────────┐
 RCWL / IR ──────>│ M4 — SENSORS, SAFETY & I/O (Advay) │──> UGV02 UART
                  │ stop priority / range / output relay│──> LED relay*
                  └─────────────────────────────────────┘
                          *optional, approval-dependent
```

| Module | Owner | Core individual RTL contribution | Verification responsibility |
|---|---|---|---|
| **M1 — Camera & Preprocessing** | **Luke** | Camera capture integration, coordinate-safe streaming filter/colour transform and reference-feature preprocessing | Pixel timing, image edge handling, brightness/feature-vector tests |
| **M2 — Perception & Tracking** | **Marcus** | Region validation, temporal target tracking and **visibility estimator** | Known-frame golden outputs, false target/stale-frame/missing-marker tests |
| **M3 — Parking & Repositioning** | **Jason** | Parking FSM, steering/speed scheduling, closed-loop return controller, baseline mux | Motion state transitions, target-loss recovery, controller convergence and bypass |
| **M4 — Sensors, Safety & Communications** | **Advay** | Sensor validity, latched safety arbitration, motion UART integration and optional LED command interface | E-stop every state, bad range, UART timeout, reverse watchdog and fault injection |

**Cross-functional roles:** Luke + Advay coordinate Verilator/system testing; Jason + Marcus coordinate arena experiments and physical bypass comparisons. **Each person remains responsible for their own RTL and testbench.**

### Frozen internal interfaces (agree by Thu 15 Oct; only change through coordinated review)

| Boundary | Planned signals / contract |
|---|---|
| M1 → M2 | `pixel_rgb565`, `pixel_x`, `pixel_y`, `pixel_valid`, `frame_start`, `frame_end` (clock domain and valid pulse specified in `docs/interfaces.md`) |
| M2 → M3 | `target_valid`, `target_x`, `target_area`, `target_id`, `observation_strobe`; later `visibility_score`, `viewing_zone_valid`, `reference_count` |
| M4 → M3 | `distance_mm`, `range_valid`, `range_stale`, `estop_latched`, optional `led_ack` |
| M3 → M4 | signed/encoded `left_cmd`, `right_cmd`, `motion_valid`, `selected_target_id`, optional `led_update_req` |
| FPGA hardware | `SW` bypass selection; IR stop must be independent of bypass path; reset and clock-domain crossing explicit |

Use **registered frame-level outputs** at the vision/control boundary. Do not feed mid-frame centroid accumulators directly into motion control. The exact bus widths, polarity and UART frame encoding are **TBD after inspection of official reference code**.

## 4. Version rungs: capability, weakness, next improvement

Versions are **cumulative**; the table lists the substantive *new* work in each rung.

| Version / verify-by | M1 — Luke | M2 — Marcus | M3 — Jason | M4 — Advay |
|---|---|---|---|---|
| **V1: Basic parking** · **Sun 18 Oct** | OV7670 valid pixel stream, RGB565 and coordinates | Simple RGB-threshold mask, centroid/area/valid | SEARCH→ALIGN→APPROACH→PARKED, P steering, basic reverse command | Ultrasonic stop, latched IR E-stop, wheel UART |
| **V2: Robust parking** · **Tue 20 Oct** | Spatial smoothing and optional calibrated colour-ratio preprocessing | Area/bounding-box rejection, reject isolated false positives | Steering deadband/filtering, alignment-aware speed, command saturation | Range validity/median filtering, command timeout |
| **V3: Repeated parking** · **Fri 23 Oct** | Stream stability during movement; lighting adaptation if data supports it | Temporal target confirmation, stale-target rejection, persistent marker detection | PARK→REVERSE→REACQUIRE→new bay; timed reverse baseline and bounded search | Reverse time limit, target-selection/LED peripheral interface if ready |
| **V4: Visibility-aware return** · **Tue 27 Oct** | Stable calibrated feature extraction across viewing distances | Multi-reference visibility score and stable viewing-zone determination | **Camera-driven reverse termination/reposition correction**, selectable **V3 timed reverse bypass** | Safe reverse supervision, sensor/command arbitration and fault response |
| **V5: Dynamic switching** *(optional)* · **Thu 29 Oct lab** | Candidate-colour processing if needed | Active-target identity/change detection and reacquisition confidence | Controlled stop, target-change replan and resume | LED protocol acknowledge/timeout, disconnection fail-safe |

### V1 → V2: false detection and unstable approach

**V1 weaknesses:** Bright reflections satisfy a fixed RGB threshold; small LED regions saturate; noise moves the centroid; constant-speed steering oscillates; noisy ultrasonic distance causes inconsistent stopping.

**V2 correction:** Filter/validate spatial regions; compare colour-ratio or chromaticity against raw RGB only if camera tests justify it; stabilise motion commands; reject stale/invalid range measurements.

**Comparison:** Same physical target at measured positions with lighting changes and distractors; log false detections, centroid error, steering reversals and stopping error. **V1 must stay functional as the baseline.**

### V2 → V3: no autonomous sequence or lost-target recovery

**V2 weaknesses:** Completes only one docking event; loses a new bay outside camera field of view; stale coordinates may carry into the next manoeuvre; no return/reacquisition cycle.

**V3 correction:** Temporal target validation, explicit rearm between bays, safe bounded reverse and search/reacquisition FSM. Initially switch lights manually if wireless interface is unready.

**Comparison:** Two or more consecutive parking attempts; record number of successful cycles, reacquisition time, reverse travel and accumulated heading drift.

### V3 → V4: fixed reverse cannot consistently restore visibility

**V3 weaknesses:** Fixed reverse time assumes constant wheel response, distance and heading. Wheel slip and oblique docking cause overshoot, undershoot or return from which another LED is outside the camera view.

**V4 correction:** Keep permanent visual markers at all bays; estimate a viewing-quality condition from reference count, image position/separation and frame-to-frame stability; end reverse/reposition when quality is sufficient. Implement **bounded corrective steering/search** only when experimentally demonstrated necessary and safe. Bypass switch selects V3 fixed-time return instead.

**Comparison:** Paired V3/V4 runs at equivalent starting positions, bays and heading offsets; measure successful new-target reacquisition, time to reacquire and return-position repeatability. A binary “all markers visible” check alone may not be novel enough to justify HD; evaluate whether a genuinely engineered visibility metric produces a material benefit.

**Caveat:** Visibility of fixed markers does not guarantee a particular future active LED is visible, nor that a straight reverse can restore a useful viewing location. Verify the arena geometry and add safe, bounded corrective search where necessary. Forward ultrasonic ranging does not cover reverse travel.

### V4 → V5: a target changes or disappears mid-approach (optional)

**V4 weakness:** Assumes the chosen target remains illuminated for the manoeuvre; a changed target or disconnected LED board could lead to outdated motion commands.

**V5 correction:** Detect invalid target identity, stop safely, clear prior tracking state, reacquire and only then resume. Add peripheral acknowledgements **only if actual hardware and approved communication interfaces support them**.

**Comparison:** Turn off/switch active target at prescribed approach points; record stop latency, wrong-bay attempts and recovery outcome. **Never destabilise verified V4 to gain V5.**

## 5. Precise development calendar

All deadlines are **end of day local Sydney time**, unless the team agrees a time earlier. **RTL DONE** means committed synthesizable source, compiles, self-checking module tests pass, interfaces documented, and `OWNERS.md` updated. **INTEGRATED** means full design compiles/runs in system simulation, not merely that files have been merged. **HARDWARE VERIFIED** means physical three-trial evidence is logged and the specified safety checks pass. Planned durations are ambitious; hardware access is the critical constraint.

| Date | Required work | Deliverable / gate |
|---|---|---|
| **Thu 15 Oct** | Kit bring-up; run supplied hardware diagnostic; check ultrasonic pin polarity; pin/clock map; camera exposure and LED size/visibility; wheel UART and IR stop individually; freeze signal interfaces | All interfaces independently characterised; fixture dimensions selected; M1–M4 skeletons & test harnesses present |
| **Fri 16 Oct** | **V1 RTL DONE by evening.** Camera capture + centroid + P controller + UART/safety pass unit tests; end-to-end simulation | Complete V1 RTL merge, automated system smoke test; begin actual camera-to-wheel runs |
| **Sat 17 Oct** | V1 physical integration/debug; collect first recorded OV7670 frames and reference outputs | At least one camera-controlled autonomous approach/stop; fix all basic safety blockers |
| **Sun 18 Oct** | **V1 HARDWARE VERIFIED**; three measured trials, E-stop/timeout tests, tag | `v1-verified` only if tests pass; V1 baseline retained |
| **Mon 19 Oct** | **V2 RTL DONE by midday/afternoon**; test smoothing, region rejection, steering improvements and range checks; integrate before evening | V2 build and Verilator system tests passing; V1/V2 comparison protocol ready |
| **Tue 20 Oct** | **V2 HARDWARE VERIFIED**; paired baseline vs new pipeline; capture recorded image data | `v2-verified`; measured improvement (or documented negative outcome) |
| **Wed 21 Oct** | V3 RTL implementation: temporal tracking, target-change state reset, timed reverse and reacquisition; ESP32 communications only if ready | V3 modules unit-tested; first two-bay sequence attempted |
| **Thu 22 Oct** | **V3 RTL DONE by midday**, integrate in afternoon; profile reverse drift at different bays/angles; establish V4 viewing-zone calibration dataset | V3 integrated and fault-tested; concrete fixed-reverse failure modes measured |
| **Fri 23 Oct** | **V3 HARDWARE VERIFIED**: two or more consecutive parking manoeuvres and fresh target detection; tag stable baseline | `v3-verified` — mandatory fallback; V4 algorithm and test cases agreed |
| **Sat 24 Oct** | V4 RTL build: reference feature extraction, visibility estimator, viewing-quality thresholds and frame stability; controller reverse-mode mux | Each V4 owner has passing preliminary unit tests; bypass design wired |
| **Sun 25 Oct** | V4 RTL refinement and co-simulation; missing/reference-noise/timeout scenarios | V4 testbench coverage, recorded-video golden vector comparisons |
| **Mon 26 Oct** | **V4 RTL DONE by midday**; full regression and synthesis; start live V4 hardware tuning | All V4 synthesizable RTL committed and system tests pass; first V4 hardware cycle |
| **Tue 27 Oct** | **V4 HARDWARE VERIFIED (primary deadline)**; three-trial performance tests, switch-bypass comparison, safety and resource/timing measurements | `v4-verified` only on actual evidence; quantitatively justified HD-candidate claim |
| **Wed 28 Oct** | **V5 RTL DONE by midday if authorised**, otherwise expand V4 trials/report. Build V5 without modifying V4 safety/working baseline | Isolated `feature/v5-target-switch` branch, tests passing before merge |
| **Thu 29 Oct — W12 lab** | **V5 optional HARDWARE VERIFIED**; dynamic target-change and fault-recovery test; demonstrate protected V4 fallback | Tag `v5-verified` only if it passes; otherwise retain `v4-verified` |
| **Fri 30 Oct – Sun 1 Nov** | Final quantitative trials; replay real inputs through RTL/golden model; fault-injection suite; predicted/actual ALM, M10K, DSP, Fmax/slack/latency | Frozen acceptance dataset, complete test log, report figures and measured datasheet |
| **Mon 2 Nov** | Final **demo bitstream and acceptance-condition freeze**; full rehearsal | Locked known-good configuration; no new features |
| **Tue 3 Nov** | Film stable end-to-end runs, verify demonstration narrative and one-page datasheet | Rehearsal and video assembly |
| **Wed 4 Nov** | **Video submission by 11:59 pm**; last safety/battery/equipment checks | Final video submitted and independently playable |
| **Thu 5 Nov** | **Live demonstration and individual Q&A** | Safety test, full run, selected performance targets and bypass |
| **Fri 6 – Sun 8 Nov** | Final report, code listing, OWNERS and resources/verification evidence | **Report/code Sunday 8 Nov, 11:59 pm** |

**Calendar note:** Sunday 18 Oct is the Sunday immediately preceding Monday 19 Oct; confirm the course convention if you refer to it as “Sunday W11”. All numeric dates above are unambiguous.

### Daily integration discipline

1. **Morning:** Report build status, blockers and downstream interface changes.
2. **Before hardware block:** RTL must compile, run its self-checking unit test and pass any required full regression.
3. **Hardware block:** Run a fixed test procedure and record raw data, parameter settings, starting positions and failures.
4. **Evening:** Merge only green builds; maintain known-good main branch and dated results.
5. **At rung deadline:** Produce actual measurement evidence, not just a working demo or completed source code.

### Stop/go rules

- **V1 missing Sun 18:** freeze new perception enhancements and solve camera→wheel integration immediately.
- **V2 incomplete Tue 20:** use the best verified detector; never delay V3 for speculative colour-space refinements.
- **Wireless/ESP32 not ready:** manually illuminate targets; keep the robot's vision/control path on FPGA.
- **V3 missing Fri 23:** put the full team on repeated parking; postpone V4 correction complexity.
- **V4 doesn't outperform V3 Tue 27:** retain measured results and revise claims; do not manufacture a favourable threshold or cherry-pick trials.
- **V5 unstable Thu 29:** discard the extension and restore the V4 tag/bitstream.

## 6. Lean planned directory structure

The following tree contains **only intended core RTL, tests, baseline artefacts and documentation**. Add files when implemented; **do not fabricate named course resources**. The `external/` section is a staging location for verified, attributed staff/Ed/previous assignment material and is **not** a folder of newly authored modules.

```text
MTRX3700_Autonomous_Parking/
├── README.md                              # this document
├── OWNERS.md                              # SID, file ownership, origin, edits
├── VERSION_HISTORY.md                     # rung gates, evidence, Git tags
├── run_all_tests.sh                       # Verilator 5.050, <5 min, fault CAUGHT
├── .gitignore
│
├── rtl/
│   ├── m1_camera/                         # Luke
│   │   ├── camera_pipeline.sv              # capture/format + stable pixel output
│   │   └── pixel_preprocess.sv             # V2+ filtering/colour, V4 features
│   ├── m2_vision/                         # Marcus
│   │   ├── target_detector.sv              # V1 centroid → V2 validated detection
│   │   ├── target_tracker.sv               # V3 temporal validity / V5 switching
│   │   └── visibility_estimator.sv         # V4 new visibility capability
│   ├── m3_control/                        # Jason
│   │   ├── parking_controller.sv           # FSM, P/speed control, V3+ sequencing
│   │   ├── reposition_controller.sv        # V3 timed vs V4 visual return
│   │   └── target_switch_controller.sv     # V5 OPTIONAL
│   ├── m4_interfaces/                     # Advay
│   │   ├── range_sensor.sv                 # ultrasonic capture + validity
│   │   ├── safety_supervisor.sv            # IR latch, stale/fault arbitration
│   │   ├── chassis_uart.sv                 # FPGA→UGV02 actuator command path
│   │   └── led_command.sv                  # optional FPGA-side light control
│   └── parking_robot_top.sv                # integrates M1–M4 + SW bypass
│
├── external/                               # VERIFIED REUSE ONLY; attribute
│   ├── ed_major_project/                  # official kit pin/hardware reference
│   ├── ed_lessons_3_5/                    # selected relevant lesson RTL/models
│   ├── assignment_1/                      # if reusable: debounce/IR/FSM helpers
│   └── assignment_2/                      # if reusable: stream/video DSP modules
│
├── sim/
│   ├── tb_m1.cpp
│   ├── tb_m2.cpp
│   ├── tb_m3.cpp
│   ├── tb_m4.cpp
│   ├── tb_parking_system.cpp               # end-to-end normal and failure tests
│   ├── tb_bypass.cpp                       # switch baseline vs custom
│   └── inject_faults.sh                   # must report CAUGHT for injected faults
│
├── golden/
│   ├── README.md                          # golden-model I/O contract
│   ├── vision_reference.py                # CPU offline reference, not robot logic
│   ├── control_reference.py               # optional offline controller reference
│   └── compare_outputs.py                 # RTL vs reference on real recordings
│
├── data/
│   ├── camera/                            # recorded real OV7670 frames/vectors
│   ├── calibration/                       # camera, LED geometry, motor/range
│   └── hardware_trials/                   # V1–V5 logs, paired bypass results
│
├── fpga/
│   ├── quartus/                           # project .qpf/.qsf/.sdc, pin assignments
│   └── reports/                           # ALM/M10K/DSP/Fmax/slack/latency
│
├── firmware/                               # ONLY if used/approved
│   ├── nano_relay/                        # communications relay, not control
│   └── stationary_led/                    # stationary output-only peripheral
│
└── docs/
    ├── interfaces.md                     # frozen bus/clock/reset contracts
    ├── test_plan.md                      # conditions, three-trial protocol
    ├── performance_datasheet.md          # three–five quantified targets
    └── architecture.md                   # diagram, decisions, limitations
```

### Reuse policy — what to look for in prior work

The items below are **candidate sources**, not confirmed exact filenames or guarantees of compatibility. Inspect the real code, keep only what is needed, and document what you reuse versus adapt.

| Source | Candidate reusable function | Conditions |
|---|---|---|
| **Ed Major Project Resources** | Adapter pin map, clock/reset conventions, OV7670/UGV02 hardware tests, serial communication helpers, sensor device models | **First choice** for hardware-specific interfaces. Verify released version and electrical constraints. |
| **Ed Lessons 3–5** | FPGA camera capture/pixel timing, UART, line buffers, image/video pipeline and verification patterns if supplied | Check actual lesson names and clock/format assumptions; do not blindly copy an entire lesson directory. |
| **Assignment 2 — Shine & Sing** | Prior synthesizable video filtering stages, stream-valid pipelines, pixel colour/threshold logic, simulation patterns | Only reuse modules whose interfaces match the camera stream; distinguish copied logic from substantial new work. |
| **Assignment 1 — Piano Tiles** | Debouncing, timers, pseudo-random/selection logic, synthesizable FSM templates, reusable self-checking bench conventions | Optional and secondary; game/timing modules are **not required** for HD. |
| **Own new project RTL** | LED target validation, tracking, viewing-zone estimator, visibility-controlled reverse and safe motor integration | Must be independently understood, verified, owned and measured. |

Do **not** copy another group's source. Any external open-source or AI-generated code must be understood and appropriately attributed under the brief and unit rules.

## 7. Test strategy and golden-model evidence

### Automated verification (every rung)

`./run_all_tests.sh` must compile/run all current units and at least one end-to-end test using **Verilator 5.050**, exit nonzero on failure, finish within **five minutes**, and perform purposeful fault injection that prints `CAUGHT` when failures are detected.

Essential corner cases:

- **M1:** reset mid-frame, early/late frame markers, incorrect or dropped pixel-valid, filter edge handling, coordinate/pipeline alignment.
- **M2:** no target, multiple blobs, a wrong-colour distractor, LED saturation, lost/stale frame, partial reference visibility, temporal-confirmation boundary.
- **M3:** target absent, wrong target after rearm, approach overshoot, reverse timeout, stop from all FSM states, bypass active while moving.
- **M4:** no ultrasonic echo, out-of-range reading, disconnected/stalled UART, latched E-stop, reset behaviour, safe reverse boundary, optional LED ACK loss.
- **System:** synthetic and recorded frame sequence leads to valid motor responses; safety can force stop; custom/bypassed path both remain operable.

### Golden-model procedure

1. Record **real camera and sensor inputs** during physical trials with metadata (frame shape, sample time, bay ID, viewing distance, ambient lighting, vehicle state).
2. Run the same input sequence through an **independent offline Python reference** in `golden/` and through the RTL testbench.
3. Compare mask/centroid, target validity, temporal state, viewing-quality score and controller mode outputs (where applicable); define tolerances and fixed-point rounding explicitly.
4. Store pass/fail evidence and explain divergence caused by frame timing, quantisation, noisy sensor values or hardware observations.
5. On robot, measure end-to-end behaviour rather than claiming offline golden matching alone proves parking accuracy.

Golden Python scripts are **offline verification only**; they must not supply real-time movement decisions to the robot.

### Physical experiment matrix (minimum)

| Rung | Test | What to record |
|---|---|---|
| V1 | Single-bay approach from marked start | Camera-to-wheel proof, stop distance, safety/E-stop |
| V2 | RGB baseline versus spatially/temporally validated detection | False detections, centroid stability, parking error |
| V3 | Repeated parking via timed reversing | Return drift, reacquisition time, successful sequence count |
| **V4** | **Same starts under V3 bypass versus visibility-aware reverse** | **New-target reacquisition, time, return-zone success, failure conditions** |
| V5 (optional) | LED change/disappearance at specified approach stages | Reaction latency, safe-stop and reacquisition correctness |

**Acceptance method:** Each target must specify a unit, condition ranges the tutor can choose within, three-trial evaluation rule, threshold and goal. Never report only the best trial. Quantities/thresholds are **TBD after hardware calibration**. The earlier pitch's stopping-gap/latency targets are preliminary, not verified.

## 8. Bypass, synthesis and configuration management

**R9 bypass design:** DE1-SoC `SW` selects the **V3 timed-reverse baseline** or **V4 visibility-aware repositioning**, with the same camera input, essential safety supervisor, UART output and parking sequence still operating. Do not bypass the emergency stop or otherwise make the baseline artificially unusable. Also consider a V1 RGB-detector bypass for diagnosing V2 perception improvements. Document which user-designed module the primary level claim rests on and show that bypass measurably affects its own relevant performance target.

**Quartus evidence:** Record estimated versus actual logic resources (ALM, M10K, DSP), achieved Fmax/slack, relevant clocks/constraints, processing latency and camera/UART timing. Avoid introducing a full-frame buffer unless required; streaming processing is preferred.

**Version control:** Use a single main repository with reproducible Git tags (only after physical test gates). Do not make separate cloned `project_v1/` ... `project_v5/` trees.

```bash
# Examples — execute only after the corresponding gate actually passes
git tag -a v1-verified -m "V1 camera-guided parking physically verified"
git tag -a v2-verified -m "V2 robust detection verified"
git tag -a v3-verified -m "V3 repeated parking verified"
git tag -a v4-verified -m "V4 visibility-aware repositioning verified"

# Isolate optional new features
# git switch -c feature/v5-target-switch
```

Keep Quartus generated build databases, waveform dumps, large recordings and unrelated assignment repositories out of version control (track only essential source, small reproducible fixtures and curated evidence). Store essential full recordings in an accessible shared location with paths/versions in the test log.

## 9. First-day decisions and risks

| Decision or risk | Owner / timing | Required action |
|---|---|---|
| Actual camera and wheel/UART reference modules | Luke + Advay, Thu 15 Oct | Audit Ed hardware resources; verify exact pins, electrical levels and API |
| Marker size, position and camera field of view | Marcus + Jason, Thu–Sat 15–17 Oct | Measure with the **actual OV7670**; favour large diffused light panels, persistent reference markers |
| Rear safety during reversing | Jason + Advay, before any reverse trial | Cleared bounded test arena, reverse timeout, supervised stop; no unsupported claim of rear obstacle sensing |
| Lighting controller legality/complexity | Advay, by Tue 20 Oct | Seek tutor approval for extra stationary hardware; prepare manual button-controlled fallback |
| HD originality of visibility estimator | Whole team, by Fri 23 Oct | Confirm scope with Viorella; establish measurable failure of V3 and nontrivial custom algorithm |
| R9 physical bypass | Jason + Advay, by Mon 26 Oct | Functional V3 fallback in the same bitstream; safety never bypassed |
| Hardware and evidence availability | Project lead, every day | Arrange safe test time, spare batteries, recordings, log ownership and backup known-good bitstream |

## 10. Definition of done

A version is **not** complete when its RTL is written. A version counts as verified only when:

- [ ] All four relevant owner modules have attributed synthesizable RTL and passing self-checking benches.
- [ ] `run_all_tests.sh` passes module/system/fault-injection coverage for that rung.
- [ ] Full FPGA design synthesises with a current constraints file and no unexplained critical timing failure.
- [ ] Live camera-derived results influence wheel actuation; emergency stop remains operational.
- [ ] The version's agreed hardware test cases have **three documented trials** and raw results.
- [ ] Known limitations, including unsuccessful trials, are recorded.
- [ ] Golden/reference comparison is updated as relevant (required by the final release).
- [ ] Git revision/tag, bitstream identity and experiment conditions are linked in `VERSION_HISTORY.md`.

**Final priority order:** verified **V3 baseline** → quantitative **V4 advancement and bypass** → final testing/documentation → **V5 only if safely achievable**. Game scoring/Whack-a-Mole logic is not necessary for the stated engineering objective or HD eligibility.

---

**References:** MTRX3700 2026 Major Project Brief (course requirements, hardware restrictions, grade-level descriptors); team's preliminary Major Project Pitch (original ownership split and initial targets); prior Assignment 1/2 and Ed lessons **to be audited against actual files before reuse**.
