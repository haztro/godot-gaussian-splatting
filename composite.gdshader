shader_type spatial;
render_mode unshaded;

uniform sampler2D accum_texture;
uniform vec2 viewport_size;
        
void vertex() {
  POSITION = vec4(VERTEX, 1.0);
}
		
void fragment() {
	
	vec4 accum = texture(accum_texture, UV);
	vec3 color = accum.rgb;

	// Output the final color
	ALBEDO.rgb = color.rgb;
	ALPHA = 1.0;
}
