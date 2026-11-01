type: Added

**WebGL 2 transform feedback and real queries**: `beginTransformFeedback`, `transformFeedbackVaryings`, `getTransformFeedbackVarying`, `bindBufferBase`/`bindBufferRange` on `TRANSFORM_FEEDBACK_BUFFER`, `pause`/`resume` (a variant of the vertex stage that writes to storage; an adapter without that says `MAX_TRANSFORM_FEEDBACK_*` are 0), `ANY_SAMPLES_PASSED` and `ANY_SAMPLES_PASSED_CONSERVATIVE` by occlusion queries, `TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN`, with results on a later task only; a vertex attribute divisor above 1.
