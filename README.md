# Godot 3D Gaussian Splatting

This is a WIP Godot 4 implementation of 3D Gaussian splatting. The splat transformations/rendering are done in the splat.glsl shader and I use compute shaders to implement bitonic sorting for sorting the splats by depth. It's a bit jank since bitonic sorting requires the array size to be a power of two. For now I just truncate the number of splats to the nearest power of 2. Radix sort would be a better choice (for gpu parallel sort) here. 

To try it out, define the "splat_filename" export as the .ply file you want to view. 

## Example Views

![bicycle](assets/bicycle.PNG)

![train](assets/train.PNG)

![garden](assets/garden.PNG)

