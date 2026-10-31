# Color formats & rendering {#colorformats}

To make sure that frames are displayed correctly, applications using PipeWire for app-to-app video sharing must follow certain rules.

To make things work for a typical non-color-managed application, you must encode color using *sRGB* encoding, with *linear alpha blending* and *premultiplied alpha*.

If you are a graphics app developer and you don't know much about color management, alpha, etc., then read the \ref colorguide section.

If you are experienced with color management and just want a spec, read the \ref colorspec version.

## How to do color and alpha properly {#colorguide}

These guidelines will help you fix a bunch of confusing color and transparency related issues in your app.

If you do not intend to send translucent frames through libfunnel (all finished frames are opaque or you only enable non-alpha color formats), then you don't necessarily have to follow them, as these issues won't affect your usage of libfunnel (even though following these guidelines is likely to improve your rendering).

However, if you want to output frames with a transparent/translucent background, unless you really know what you're doing, you really should follow these rules:

* Premultiply all your texture data before uploading it to the GPU (or use blits or shaders or whatever to do it if you want to be fancy, but it has to happen *before* you sample from any textures during rendering). If you aren't doing this already, trust me, it will make your life much easier.
* When shaders output color data, make sure it is premultiplied (multiply R,G,B by A if they don't already come from a premultiplied texture, or if you're multiplying in an alpha factor also multiply it to R,G,B, etc.).
* Use sRGB sampling for textures. For OpenGL, that means using the `SRGB8_EXT` or `SRGB8_ALPHA8_EXT` internal format (see [EXT_texture_sRGB](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_texture_sRGB.txt)). For Vulkan, use one of the `_SRGB` formats for images.
* Use sRGB mode for your framebuffer. For OpenGL, that means calling `glEnable(GL_FRAMEBUFFER_SRGB)` (see [EXT_framebuffer_sRGB](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_framebuffer_sRGB.txt)). For Vulkan, use one of the `_SRGB` formats for attachment images (the buffers libfunnel gives you already use sRGB mode).
* If you want a transparent background, make sure to clear your framebuffer to the color *(0., 0., 0., 0.)* (transparent black).
* Set up the blending function for premultiplied blending. For OpenGL, that is `glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)` for standard compositing (alpha-over). For Vulkan, you might use:

~~~{.c}
    colorBlendAttachment.srcColorBlendFactor = VK_BLEND_FACTOR_ONE;
    colorBlendAttachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    colorBlendAttachment.colorBlendOp = VK_BLEND_OP_ADD;
    colorBlendAttachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    colorBlendAttachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    colorBlendAttachment.alphaBlendOp = VK_BLEND_OP_ADD;
~~~

When you premultiply alpha, **this needs to happen in linear light**. That means that if you are premultiplying a texture which is stored in sRGB straight alpha (typical PNGs, etc.), you need to use this computation when loading your texture data:

~~~{.c}
    rgb = linear_to_srgb(srgb_to_linear(rgb) * alpha)
~~~
    
What this achieves is:

* Texture sampling is gamma-correct (no weird gamma effects with fine details)
* Texture sampling with alpha is correct (no white/colored/artifacted edges). No, you don't need to "bleed" your textures, that's a horrible hack that is not needed if you do the above. Things will "just work"!
* Alpha blending will happen in linear light, which will give "natural" results (like light behaves in the real world) that look better.
* Framebuffer transparency will work properly, so the resulting frame can have a transparent background.
* Additive blending works **and composites at the receiving application correctly**, which means bloom and emissive surfaces look correct and awesome, [like this](https://bsky.app/profile/danilotakagi.bsky.social/post/3mdvvmtgv3b2o). This is impossible without premultiplied alpha.

In other words, your color will [not be broken](https://www.youtube.com/watch?v=LKnqECcg6Gw)! If you want to read more, check [this](https://www.realtimerendering.com/blog/gpus-prefer-premultiplication/) article and [this](https://amindforeverprogramming.blogspot.com/2013/07/why-alpha-premultiplied-colour-blending.html) article.

### But this is too hard / changes how I already do things!

If you do not intend to ever send frames with transparency, then you can do whatever you want (your framebuffer is already being interpreted as sRGB at the end of the day anyway, if you aren't doing explicit color management).

However, if you want transparency to work, you **have** to premultiply, because GPUs **simply cannot blend two translucent colors together in hardware without premultiplication**.

### Really?

Really.

<small>Technically you can do it in a shader with [this](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_shader_framebuffer_fetch.txt) but that only works well on mobile GPUs and Apple M GPUs. It works on Intel but it's slower, and it is not supported on AMD and Nvidia at all. So yeah.</small>

### I did what you said, and it changed the way my transparent textures look!

Since this approach does blending in linear light (the way it's supposed to work), things will look subtly different to many image authoring applications if you have large semi-transparent areas in your textures. Some image editors like GIMP already do this by default, and some apps like OBS already blend images like this by default, so you will be doing youself a favor by getting used to it!

### I really don't want my transparent textures to look different! It's not what the artist intended!

Sorry, apps like OBS will blend in linear light, and it's the only reasonable way to do it too. If you really, really want to, you can do your own *internal* blending in gamma/sRGB space. This will make your transparent textures look the same *when overlaid on other opaque areas inside your app* (but they will still blend differently in the receiving app, if the final color has transparency). To do this, however, you have to do an awkward conversion:

* Turn off all sRGB settings (texture, framebuffer) while rendering. You still have to premultiply (sorry, them's the rules), but you can just do `rgb = orig_rgb * alpha`. Or, if you really want to keep the "bleeding" workaround and not touch your texture data, multiply in your shader after texture sampling.
* Once your translucent frame is rendered, you **must postprocess your framebuffer to convert the RGB encoding** to premultiplied in linear light, which means you need to read your framebuffer and run it through a shader before sending it to libfunnel. The calculation you have to do is:

~~~{.c}
    if (alpha != 0)
        rgb = linear_to_srgb(srgb_to_linear(rgb / alpha) * alpha)
~~~

Note that this will only work as intended if you don't have emissive pixels (that is, pixels where color > alpha). Emissive/additive blending *really* doesn't make any sense if you don't do blending in linear space. There's just no way to make that math work out, because by the time you've blended colors "wrong", there's no way to make the output correct when blending "right", as the math becomes ambiguous.

### I want to render with a background, but then make the background transparent when I send frames to libfunnel/PipeWire

Unfortunately, that isn't possible to do in one go. You have to do things the other way around, in two steps: first render your foreground to a transparent buffer, which you will send to libfunnel, and then composite that buffer on top of whatever background you want to display to the user in your app.

### But I could do that with Spout2!

No you couldn't. Not correctly.

### But it worked???

Not if you had any semi-transparent pixels at all. You'd get the background bleeding through.

### It worked for me.

Sigh. In a *very specific case*, this could work correctly with Spout2 on Windows, if and only if all your rendered foreground pixels are opaque (no MSAA, no translucent textures, etc.)

In this case, you could theoretically render some background stuff to your framebuffer while keeping the framebuffer alpha channel at 0.0, then render a foreground with alpha at 1.0, and send the result to Spout2, and have users select the "Default" blending mode (straight alpha), and end up with something that kind of works (kind of, because sampling in the destination would still be broken in some cases if the source is resized at all in OBS).

Because this requires manual configuration by users, and it only works in a specific case, it will never be supported in PipeWire/libfunnel directly. Sorry. If you really want to shoehorn the same result in when using libfunnel, you have to add a postprocess premultiply pass while copying into the libfunnel buffer:

~~~{.c}
    rgb = rgb * alpha;
~~~

Or, since all your pixels are either fully opaque or fully transparent (right?), equivalently:

~~~{.c}
    if (alpha != 1.0)
        rgb = (0., 0., 0.);
~~~

But really, please do your users a favor and switch to a premultiplied pipeline. I promise it will be worth it in the long run.

## Color specification {#colorspec}

This document currently covers RGB and RGBA formats. YUV and other encodings are considered out of scope at this time.

### Color encoding

In the absence of PipeWire metadata specifying otherwise, the color must be encoded as follows:

For integer formats:

* Transfer function: sRGB
* RGB component value range: minimum to maximum integer value (full range)
* SDR luminance range
* Color primaries: sRGB (same as BT.709)
* Alpha: minimum to maximum integer value, linear, with RGB channels **premultiplied in linear space** (*before* applying the sRGB encoding)


For floating-point formats:

* Transfer function: extended-linear
* RGB component range: 0.0 to 1.0 for SDR colors inside the sRGB volume, extended outside that range ([scRGB](https://wayland.app/protocols/color-management-v1#wp_color_manager_v1:request:create_windows_scrgb))
* SDR luminance range in principle (exceeding 1.0 luminance is possible for HDR, but this should be avoided in the absence of HDR metadata)
* Color primaries: sRGB (same as BT.709)
* Alpha: 0.0 to 1.0, linear, with RGB channels **premultiplied**.

Although PipeWire has a `SPA_VIDEO_FLAG_PREMULTIPLIED_ALPHA` flag, this is considered legacy and is not used nor checked by any software. Alpha **should always be premultiplied** regardless of the state of this flag. Straight alpha is **not supported** and should never be used.
