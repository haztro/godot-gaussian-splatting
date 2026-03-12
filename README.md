# Godot 3D Gaussian Splatting

This is a WIP Godot 4.3 implementation of 3D Gaussian splatting. The current renderer keeps the pipeline simple: a compute preprocess pass projects splats into screen space and builds depth sort keys for visible splats, a global radix sort orders those keys back-to-front, and the draw pass shades lightweight quads from cached projected data.

To keep interaction smooth, the renderer reuses the last completed sort order while the camera is moving and only refreshes sorting on a configurable cadence. During those in-motion rebuilds it can use a cheaper SH degree, then switch back to full SH after motion stops so the image can settle. The radix sort now batches multiple 512-element blocks per dispatched workgroup to cut the number of histogram rows and reduce the sort shader's expensive global-offset scan.

To try it out, define the "splat_filename" export as the .ply file you want to view.
