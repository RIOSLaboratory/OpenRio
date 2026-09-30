# DUT_KIND=rtl_cache: BE RTL (same as rtl_v1.f) + OR_Cache RTL + D-side downstream interface; FE is still fe_agent.
# Evaluation root is orbe_bt_env/; OR_Cache RTL is in ../../src/core/cache_rtl_v1/. Protocol packages are compiled by common.f.
-f cfg/filelist/rtl_v1.f

-f cfg/filelist/cache_rtl.f
