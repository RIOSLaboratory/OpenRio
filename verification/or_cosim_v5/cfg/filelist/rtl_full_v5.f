# DUT_KIND=rtl_full_v5 -- ST（整机）: v5 BE RTL + OR_FE RTL + OR_Cache RTL + D-side downstream interface.
#
# This is the v5 copy of rtl_full.f. The only difference is which BE RTL tree
# the DUT slot is filled from: rtl_v5.f instead of rtl_v1.f.
#
#   FE slot     : OR_FE RTL   (or_fe_top, from src/core/fe_rtl_v1/)
#   BE slot     : v5 BE RTL   (from openrios/work/or-be-draft/rtl_v5/)
#   Cache slot  : OR_Cache RTL(from src/core/cache_rtl_v1/)
#   cache_agent : only serves as FE's L2/PTW and D-side model sync / downstream
#                 responses -- it is NOT the DUT.
#
# This is the "ST, not BT" level: no agent sits in the DUT slot.
-f cfg/filelist/rtl_fe_v5.f

-f cfg/filelist/cache_rtl.f
