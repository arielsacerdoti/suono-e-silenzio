IMAGES FOLDER
=============

Please add the following images to make the site complete:

1. hero.jpg
   ─────────
   The full-screen background on the homepage.
   Recommended: a large (1920×1080px+), high-quality photograph of nature,
   meditation, mountains, forest, water, or abstract "sound/silence" imagery.
   Free sources:
   - https://unsplash.com/s/photos/meditation-nature
   - https://unsplash.com/s/photos/forest-light
   - https://www.pexels.com/search/meditation/
   Place file here as: images/hero.jpg

2. manuel-katz.jpg
   ────────────────
   A portrait photo of Manuel Katz.
   Recommended size: at least 600×800px (portrait orientation).
   Place file here as: images/manuel-katz.jpg

   Once added, open about.html and index.html and replace:
      <div class="img-placeholder" ...>&#9786;</div>
   with:
      <img src="images/manuel-katz.jpg" alt="Manuel Katz">


YOUTUBE VIDEO IDs
=================
The sessions in data/sessions.json currently have placeholder IDs
(PLAYLIST_VIDEO_1, PLAYLIST_VIDEO_2, etc.) because the playlist page
requires a browser to render.

To update with real IDs:
1. Open: https://www.youtube.com/playlist?list=PLBnExi1jlBdj2QnlLQ144sdKYSi3bfFYK
2. Right-click each video → "Copy link"
3. Extract the v=XXXXXXX part
4. Update each "id" field in data/sessions.json

This will enable real YouTube thumbnails and direct video links.


BIT PAYMENT LINK
================
In dana.html, find these two lines and replace with your actual Bit details:

   const BIT_PHONE    = '050-000-0000';   ← your Bit-registered phone
   const BIT_WEB      = 'https://bit.ly/donation-link';  ← your Bit profile URL
