# Godot 3D Gaussian Splatting

This is a WIP Godot 4.3 implementation of 3D Gaussian splatting. The splat transformations/rendering are done in the splat.glsl shader and I use compute shaders to implement radix sorting for sorting the splats by depth. 

To try it out, define the "splat_filename" export as the .ply file you want to view. 

## Example Views

![bicycle](assets/bicycle.PNG)

![train](assets/train.PNG)

![garden](assets/garden.PNG)

