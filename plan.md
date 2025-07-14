# hCaptcha + Rate Limiting Implementation Plan

## Security Enhancement for ICE Reporter

### Completed Steps:
- [x] Create implementation plan
- [ ] Add hCaptcha dependency and configure environment
- [ ] Create rate limiting GenServer module
- [ ] Add rate limiting logic to LiveView
- [ ] Add hCaptcha widget to frontend (map popup)
- [ ] Update JavaScript to handle captcha verification
- [ ] Add server-side hCaptcha verification
- [ ] Integrate rate limiting checks in report creation
- [ ] Test complete flow and polish UI integration

### Implementation Details:

**Rate Limiting Strategy:**
- Track submissions per IP address
- Allow 3 reports per 10 minutes per IP
- After limit reached, require hCaptcha for additional reports
- Reset counters every 10 minutes

**hCaptcha Integration:**
- Show captcha widget in map popup after activity type selection
- Verify captcha token server-side before creating report
- Maintain ICEE theme styling around captcha widget
- Graceful error handling for captcha failures

**User Experience:**
- First 3 reports: seamless (no captcha)
- Subsequent reports: hCaptcha verification required
- Clear messaging about rate limits
- Maintains anonymous reporting
