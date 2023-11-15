# godot-splat

WIP attempt at getting 3d-gaussian splatting to work in Godot as simply as possible. This implementation uses Godot's meshinstancing to draw a quad for each gaussian to be rendered to. Unfortunately Godot doesn't provide order-independent transparency, so at the moment I just remove any transparent fragments based on a threshold. There might be a way to manually sort vertices in a compute shader but I'm not that familiar with Godot's graphics pipeline yet.

To load in the .ply files, I compiled a gdextension to use [happly](https://github.com/nmwsharp/happly) and have provided the binaries. Throw in a .ply file named "point_cloud.ply" and try it yourself - fair warning, the bigger files (1G+ take a while to load). Here's what it looks like currently:

![bicycle](assets/bicycle.png)

![train](assets/train.png)

![garden](assets/garden.png)
