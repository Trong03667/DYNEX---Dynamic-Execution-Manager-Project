#import "DXOverlay.h"
#import "DXLoader.h"
#import "DXLog.h"

#import <UIKit/UIKit.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* ======================================================================
 *  Màu sắc & tiện ích dựng UI
 * ====================================================================== */

static inline UIColor *DXRGBA(int r, int g, int b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}
#define kPanelBG  DXRGBA(18, 18, 22, 0.97)
#define kCard     DXRGBA(23, 23, 28, 1)
#define kLine     DXRGBA(255, 255, 255, 0.08)
#define kText     DXRGBA(242, 242, 245, 1)
#define kMuted    DXRGBA(139, 139, 151, 1)
#define kAccent   DXRGBA(124, 92, 255, 1)
#define kCyan     DXRGBA(76, 201, 240, 1)
#define kGreen    DXRGBA(50, 213, 131, 1)
#define kRed      DXRGBA(255, 93, 108, 1)
#define kOrange   DXRGBA(255, 176, 64, 1)

static UILabel *DXLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

static UIButton *DXButton(NSString *title, UIColor *bg, UIColor *fg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 10;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [b.heightAnchor constraintEqualToConstant:36].active = YES;
    return b;
}

static UIButton *DXIconButton(NSString *symbol, UIColor *tint) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.tintColor = tint;
    [b.widthAnchor constraintEqualToConstant:34].active = YES;
    [b.heightAnchor constraintEqualToConstant:34].active = YES;
    return b;
}

static UIView *DXLine(void) {
    UIView *v = [[UIView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.backgroundColor = kLine;
    [v.heightAnchor constraintEqualToConstant:1].active = YES;
    return v;
}

static void DXPin(UIView *v, UIView *container, UIEdgeInsets in) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:container.topAnchor constant:in.top],
        [v.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:in.left],
        [v.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-in.right],
        [v.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-in.bottom]
    ]];
}

static UIView *DXWrap(UIView *inner, UIEdgeInsets in, UIColor *bg) {
    UIView *w = [[UIView alloc] init];
    w.translatesAutoresizingMaskIntoConstraints = NO;
    if (bg) w.backgroundColor = bg;
    [w addSubview:inner];
    DXPin(inner, w, in);
    return w;
}

static NSString *DXFormat(double v, NSString *unit) {
    return [NSString stringWithFormat:@"%g%@", v, unit ?: @""];
}

/* Tìm cửa sổ của game (để bắt chước thanh trạng thái, trả lại key window sau khi chọn file) */
static UIWindow *DXFindGameWindow(UIWindow *except, BOOL keyOnly) {
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) [all addObjectsFromArray:((UIWindowScene *)s).windows];
    }
    [all addObjectsFromArray:UIApplication.sharedApplication.windows];
    UIWindow *fallback = nil;
    for (UIWindow *w in all) {
        if (w == except || w.hidden) continue;
        if (w.isKeyWindow) return w;
        if (!keyOnly && !fallback && w.rootViewController) fallback = w;
    }
    return fallback;
}

/* ======================================================================
 *  Cửa sổ trong suốt, chỉ bắt chạm trên các view của DYNEX
 * ====================================================================== */

@interface DXBlockTarget : NSObject
@property (nonatomic, copy) void (^block)(id sender);
- (void)invoke:(id)sender;
@end
@implementation DXBlockTarget
- (void)invoke:(id)sender { if (self.block) self.block(sender); }
@end

@interface DXPassWindow : UIWindow
@end
@implementation DXPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;   /* chạm xuyên xuống game */
    return v;
}
@end

@interface DXRootViewController : UIViewController
@property (nonatomic, copy) void (^onLayout)(void);
@end
@implementation DXRootViewController
- (void)loadView {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = UIColor.clearColor;
    self.view = v;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.onLayout) self.onLayout();
}
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (UIViewController *)gameVC {
    UIWindow *w = DXFindGameWindow(self.view.window, NO);
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
/* Bắt chước game để không làm hiện thanh trạng thái / vạch Home */
- (BOOL)prefersStatusBarHidden { UIViewController *g = [self gameVC]; return g ? g.prefersStatusBarHidden : NO; }
- (UIStatusBarStyle)preferredStatusBarStyle { UIViewController *g = [self gameVC]; return g ? g.preferredStatusBarStyle : UIStatusBarStyleDefault; }
- (BOOL)prefersHomeIndicatorAutoHidden { UIViewController *g = [self gameVC]; return g ? g.prefersHomeIndicatorAutoHidden : NO; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { UIViewController *g = [self gameVC]; return g ? g.preferredScreenEdgesDeferringSystemGestures : UIRectEdgeNone; }
@end

/* ======================================================================
 *  Bubble tròn: kéo thả, hít mép, mờ đi khi không dùng, nhớ vị trí
 * ====================================================================== */

@interface DXBubble : UIView
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) NSString *saveKey;
- (instancetype)initWithSize:(CGFloat)size text:(NSString *)text hue:(double)hue main:(BOOL)main;
- (void)setDefaultFractionX:(CGFloat)fx y:(CGFloat)fy;
- (void)applyFraction;
- (void)setCount:(NSUInteger)n;
- (void)wake;
@end

@implementation DXBubble {
    CGFloat _size;
    CGFloat _fx, _fy;
    CGPoint _panStart;
    NSInteger _dimGen;
    BOOL _main;
    UILabel *_badge;
}

- (instancetype)initWithSize:(CGFloat)size text:(NSString *)text hue:(double)hue main:(BOOL)main {
    CGRect f = CGRectMake(0, 0, size, size);
    if ((self = [super initWithFrame:f])) {
        _size = size;
        _main = main;
        _fx = main ? 0.97 : 0.04;
        _fy = main ? 0.38 : 0.30;

        self.backgroundColor = DXRGBA(20, 20, 26, 1);
        self.layer.cornerRadius = size / 2;
        self.layer.borderWidth = 1;
        self.layer.borderColor = DXRGBA(255, 255, 255, 0.22).CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:f].CGPath;

        UIColor *c1 = kAccent, *c2 = kCyan;
        if (!main) {
            double h = fmod(fmax(hue, 0), 360) / 360.0;
            double h2 = fmod(fmax(hue, 0) + 40, 360) / 360.0;
            c1 = [UIColor colorWithHue:h saturation:0.75 brightness:1 alpha:1];
            c2 = [UIColor colorWithHue:h2 saturation:0.85 brightness:0.85 alpha:1];
        }
        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = f;
        g.cornerRadius = size / 2;
        g.startPoint = CGPointMake(0, 0);
        g.endPoint = CGPointMake(1, 1);
        g.colors = @[(id)c1.CGColor, (id)c2.CGColor];
        [self.layer addSublayer:g];

        UILabel *l = [[UILabel alloc] initWithFrame:f];
        l.text = text;
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:(main ? 23 : 14) weight:UIFontWeightHeavy];
        l.textColor = UIColor.whiteColor;
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.6;
        [self addSubview:l];

        if (main) {
            UIView *ring = [[UIView alloc] initWithFrame:CGRectInset(f, 5, 5)];
            ring.userInteractionEnabled = NO;
            ring.layer.cornerRadius = (size - 10) / 2;
            ring.layer.borderWidth = 1.5;
            ring.layer.borderColor = DXRGBA(255, 255, 255, 0.35).CGColor;
            [self addSubview:ring];
        }

        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel = main ? @"DYNEX" : text;

        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)]];
    }
    return self;
}

- (void)setSaveKey:(NSString *)saveKey {
    _saveKey = [saveKey copy];
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:[@"dynex.pos." stringByAppendingString:saveKey]];
    if (a.count == 2 && [a[0] isKindOfClass:[NSNumber class]] && [a[1] isKindOfClass:[NSNumber class]]) {
        _fx = fmin(fmax([a[0] doubleValue], 0), 1);
        _fy = fmin(fmax([a[1] doubleValue], 0), 1);
    }
}

- (void)setDefaultFractionX:(CGFloat)fx y:(CGFloat)fy {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:[@"dynex.pos." stringByAppendingString:_saveKey ?: @""]];
    if (a.count == 2) return;   /* đã có vị trí lưu */
    _fx = fx; _fy = fy;
}

- (CGPoint)clamp:(CGPoint)c {
    UIView *sv = self.superview;
    if (!sv) return c;
    UIEdgeInsets in = sv.safeAreaInsets;
    CGRect b = sv.bounds;
    CGFloat h = _size / 2, m = 6;
    CGFloat minX = in.left + m + h, maxX = b.size.width - in.right - m - h;
    CGFloat minY = in.top + m + h,  maxY = b.size.height - in.bottom - m - h;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    return CGPointMake(fmin(fmax(c.x, minX), maxX), fmin(fmax(c.y, minY), maxY));
}

- (void)applyFraction {
    UIView *sv = self.superview;
    if (!sv || sv.bounds.size.width < 1 || sv.bounds.size.height < 1) return;
    self.center = [self clamp:CGPointMake(_fx * sv.bounds.size.width, _fy * sv.bounds.size.height)];
}

- (void)storeFraction {
    UIView *sv = self.superview;
    if (!sv || sv.bounds.size.width < 1 || sv.bounds.size.height < 1) return;
    _fx = self.center.x / sv.bounds.size.width;
    _fy = self.center.y / sv.bounds.size.height;
    if (_saveKey.length) {
        [[NSUserDefaults standardUserDefaults] setObject:@[@(_fx), @(_fy)] forKey:[@"dynex.pos." stringByAppendingString:_saveKey]];
    }
}

- (void)wake {
    _dimGen++;
    NSInteger gen = _dimGen;
    self.alpha = 1;
    __weak DXBubble *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DXBubble *s = ws;
        if (!s || s->_dimGen != gen) return;
        [UIView animateWithDuration:0.4 animations:^{ s.alpha = 0.55; }];
    });
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    [self wake];
    if (self.onTap) self.onTap();
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *sv = self.superview;
    if (!sv) return;
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _panStart = self.center;
            [self wake];
            [UIView animateWithDuration:0.15 animations:^{ self.transform = CGAffineTransformMakeScale(1.1, 1.1); }];
            break;
        case UIGestureRecognizerStateChanged: {
            CGPoint t = [g translationInView:sv];
            self.center = [self clamp:CGPointMake(_panStart.x + t.x, _panStart.y + t.y)];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            UIEdgeInsets in = sv.safeAreaInsets;
            CGRect b = sv.bounds;
            CGFloat h = _size / 2, m = 6;
            CGPoint c = self.center;
            c.x = (c.x < b.size.width / 2) ? (in.left + m + h) : (b.size.width - in.right - m - h);
            c = [self clamp:c];
            [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5
                                options:UIViewAnimationOptionAllowUserInteraction
                             animations:^{ self.center = c; self.transform = CGAffineTransformIdentity; }
                             completion:nil];
            _panStart = c;
            self.center = c;   /* giá trị đích để lưu */
            [self storeFraction];
            break;
        }
        default: break;
    }
}

- (void)setCount:(NSUInteger)n {
    if (!_main) return;
    if (!_badge) {
        _badge = [[UILabel alloc] init];
        _badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
        _badge.textColor = DXRGBA(4, 33, 15, 1);
        _badge.backgroundColor = kGreen;
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.layer.cornerRadius = 9.5;
        _badge.clipsToBounds = YES;
        [self addSubview:_badge];
    }
    _badge.hidden = (n == 0);
    _badge.text = [NSString stringWithFormat:@"%lu", (unsigned long)n];
    CGFloat w = fmax(19, [_badge.text sizeWithAttributes:@{NSFontAttributeName: _badge.font}].width + 10);
    _badge.frame = CGRectMake(_size - w + 3, -3, w, 19);
}

@end

/* ======================================================================
 *  Thẻ tweak trong danh sách
 * ====================================================================== */

@interface DXCardView : UIView
@property (nonatomic, strong, readonly) DXPlugin *plugin;
@property (nonatomic, copy) void (^onRemove)(DXPlugin *);
@property (nonatomic, copy) void (^onOpenOwnUI)(DXPlugin *);
- (instancetype)initWithPlugin:(DXPlugin *)p;
- (void)refresh;
@end

@implementation DXCardView {
    DXPlugin *_p;
    NSMutableArray<DXBlockTarget *> *_targets;
    UILabel *_nameLabel, *_metaLabel, *_msgLabel;
    UISwitch *_switch;
    UIButton *_trash, *_retry;
    UIStackView *_controls;
    BOOL _built;
}

- (DXPlugin *)plugin { return _p; }

- (void)hook:(UIControl *)c event:(UIControlEvents)e block:(void (^)(id))blk {
    DXBlockTarget *t = [[DXBlockTarget alloc] init];
    t.block = blk;
    [_targets addObject:t];
    [c addTarget:t action:@selector(invoke:) forControlEvents:e];
}

- (instancetype)initWithPlugin:(DXPlugin *)p {
    if ((self = [super initWithFrame:CGRectZero])) {
        _p = p;
        _targets = [NSMutableArray array];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = kCard;
        self.layer.cornerRadius = 16;
        self.layer.borderWidth = 1;
        self.layer.borderColor = kLine.CGColor;
        self.clipsToBounds = YES;

        UIStackView *root = [[UIStackView alloc] init];
        root.axis = UILayoutConstraintAxisVertical;
        root.spacing = 10;
        [self addSubview:root];
        DXPin(root, self, UIEdgeInsetsMake(12, 12, 12, 12));

        /* Hàng chính */
        UIView *iconBox = [[UIView alloc] init];
        iconBox.translatesAutoresizingMaskIntoConstraints = NO;
        iconBox.backgroundColor = DXRGBA(124, 92, 255, 0.14);
        iconBox.layer.cornerRadius = 12;
        [iconBox.widthAnchor constraintEqualToConstant:38].active = YES;
        [iconBox.heightAnchor constraintEqualToConstant:38].active = YES;
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"doc"]];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.tintColor = kAccent;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [iconBox addSubview:icon];
        [NSLayoutConstraint activateConstraints:@[
            [icon.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
            [icon.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:19],
            [icon.heightAnchor constraintEqualToConstant:19]
        ]];

        _nameLabel = DXLabel(@"", 14, UIFontWeightSemibold, kText);
        _nameLabel.numberOfLines = 1;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _metaLabel = DXLabel(@"", 11, UIFontWeightRegular, kMuted);
        UIStackView *info = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _metaLabel]];
        info.axis = UILayoutConstraintAxisVertical;
        info.spacing = 3;
        [info setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        _trash = DXIconButton(@"trash", kMuted);
        _switch = [[UISwitch alloc] init];
        _switch.onTintColor = kGreen;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iconBox, info, _trash, _switch]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 8;
        [root addArrangedSubview:row];

        /* Thông báo lỗi / ghi chú + nút thử lại */
        _msgLabel = DXLabel(@"", 12, UIFontWeightRegular, kRed);
        _msgLabel.hidden = YES;
        [root addArrangedSubview:_msgLabel];

        _retry = DXButton(@"Thử nạp lại", DXRGBA(255, 176, 64, 0.2), kText);
        _retry.hidden = YES;
        [root addArrangedSubview:_retry];

        /* Vùng nút con */
        _controls = [[UIStackView alloc] init];
        _controls.axis = UILayoutConstraintAxisVertical;
        _controls.spacing = 12;
        _controls.hidden = YES;
        [root addArrangedSubview:_controls];

        __weak DXCardView *ws = self;
        DXPlugin *plugin = p;
        [self hook:_trash event:UIControlEventTouchUpInside block:^(id s) {
            DXCardView *c = ws;
            if (c && c.onRemove) c.onRemove(plugin);
        }];
        [self hook:_retry event:UIControlEventTouchUpInside block:^(id s) {
            [[DXLoader shared] releaseQuarantineForPlugin:plugin];
        }];
        UISwitch *sw = _switch;
        [self hook:_switch event:UIControlEventValueChanged block:^(id s) {
            BOOL ok = [[DXLoader shared] setEnabled:sw.isOn forPlugin:plugin];
            if (!ok) [sw setOn:plugin.enabled animated:YES];
        }];

        if (p.state == DXPluginStateLoaded) [self buildControls];
        [self refreshAnimated:NO];
    }
    return self;
}

- (void)flushButtons:(NSMutableArray<UIButton *> *)pending {
    if (!pending.count) return;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:pending];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.distribution = UIStackViewDistributionFillEqually;
    if (pending.count == 1) [row addArrangedSubview:[[UIView alloc] init]];
    [_controls addArrangedSubview:row];
    [pending removeAllObjects];
}

- (void)buildControls {
    if (_built) return;
    _built = YES;
    DXPlugin *p = _p;
    [_controls addArrangedSubview:DXLine()];

    if (p.ownUI) {
        UILabel *n = DXLabel([NSString stringWithFormat:@"Tweak này có giao diện riêng. Bubble «%@» đã hiện trên màn hình, bấm vào để mở menu.", p.bubbleText],
                             12, UIFontWeightRegular, kMuted);
        UIButton *open = DXButton(@"Mở giao diện", DXRGBA(124, 92, 255, 0.18), kText);
        __weak DXCardView *ws = self;
        [self hook:open event:UIControlEventTouchUpInside block:^(id s) {
            DXCardView *c = ws;
            if (c && c.onOpenOwnUI) c.onOpenOwnUI(p);
        }];
        [_controls addArrangedSubview:n];
        [_controls addArrangedSubview:open];
        return;
    }
    if (p.controls.count == 0) {
        [_controls addArrangedSubview:DXLabel(@"Tweak này không có tuỳ chọn nào. Nó chạy ngầm sau khi bật.", 12, UIFontWeightRegular, kMuted)];
        return;
    }

    NSMutableArray<UIButton *> *pending = [NSMutableArray array];
    for (NSDictionary *c in p.controls) {
        NSString *kind = c[@"kind"], *cid = c[@"id"], *label = c[@"label"];

        if ([kind isEqualToString:@"button"]) {
            UIButton *b = DXButton(label, DXRGBA(124, 92, 255, 0.18), kText);
            __weak UIButton *wb = b;
            [self hook:b event:UIControlEventTouchUpInside block:^(id s) {
                [[DXLoader shared] performAction:cid forPlugin:p];
                UIButton *bb = wb;
                if (!bb) return;
                UIColor *old = bb.backgroundColor;
                bb.backgroundColor = DXRGBA(50, 213, 131, 0.35);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ bb.backgroundColor = old; });
            }];
            [pending addObject:b];
            if (pending.count == 2) [self flushButtons:pending];
            continue;
        }
        [self flushButtons:pending];

        if ([kind isEqualToString:@"toggle"]) {
            UILabel *l = DXLabel(label, 13, UIFontWeightRegular, kText);
            [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
            UISwitch *sw = [[UISwitch alloc] init];
            sw.onTintColor = kGreen;
            sw.on = [p valueForOption:cid] != 0;
            sw.transform = CGAffineTransformMakeScale(0.85, 0.85);
            [self hook:sw event:UIControlEventValueChanged block:^(id s) {
                [[DXLoader shared] setOption:cid value:(sw.isOn ? 1 : 0) forPlugin:p];
            }];
            UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[l, sw]];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.alignment = UIStackViewAlignmentCenter;
            row.spacing = 8;
            [_controls addArrangedSubview:row];

        } else if ([kind isEqualToString:@"slider"]) {
            double lo = [c[@"min"] doubleValue], hi = [c[@"max"] doubleValue], st = [c[@"step"] doubleValue];
            NSString *unit = c[@"unit"] ?: @"";
            UILabel *l = DXLabel(label, 13, UIFontWeightRegular, kText);
            [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
            UILabel *val = DXLabel(DXFormat([p valueForOption:cid], unit), 13, UIFontWeightSemibold, kCyan);
            val.numberOfLines = 1;
            UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[l, val]];
            top.axis = UILayoutConstraintAxisHorizontal;

            UISlider *sl = [[UISlider alloc] init];
            sl.minimumValue = (float)lo;
            sl.maximumValue = (float)hi;
            sl.value = (float)[p valueForOption:cid];
            sl.minimumTrackTintColor = kAccent;
            [self hook:sl event:UIControlEventValueChanged block:^(id s) {
                double v = round((sl.value - lo) / st) * st + lo;
                v = fmin(fmax(v, lo), hi);
                if (fabs(sl.value - v) > 1e-6) sl.value = (float)v;
                val.text = DXFormat(v, unit);
                [[DXLoader shared] setOption:cid value:v forPlugin:p];
            }];
            UIStackView *box = [[UIStackView alloc] initWithArrangedSubviews:@[top, sl]];
            box.axis = UILayoutConstraintAxisVertical;
            box.spacing = 4;
            [_controls addArrangedSubview:box];
        }
    }
    [self flushButtons:pending];
}

- (void)refresh { [self refreshAnimated:(self.window != nil)]; }

- (void)refreshAnimated:(BOOL)animated {
    DXPlugin *p = _p;
    BOOL loaded = (p.state == DXPluginStateLoaded);
    BOOL on = loaded && p.enabled;

    _nameLabel.text = loaded ? p.name : p.fileName;

    NSString *status; UIColor *sc;
    switch (p.state) {
        case DXPluginStateLoaded:      status = on ? @"● Đã nạp" : @"● Đang đóng băng"; sc = on ? kGreen : kMuted; break;
        case DXPluginStateQuarantined: status = @"● Bị cô lập"; sc = kOrange; break;
        default:                       status = @"● Lỗi"; sc = kRed; break;
    }
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:status attributes:@{
        NSForegroundColorAttributeName: sc,
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]}];
    NSMutableString *tail = [NSMutableString string];
    if (p.fileSize) [tail appendFormat:@"  %@", [NSByteCountFormatter stringFromByteCount:(long long)p.fileSize countStyle:NSByteCountFormatterCountStyleFile]];
    if (loaded && p.ownUI) [tail appendString:@"  ·  Giao diện riêng"];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:tail attributes:@{
        NSForegroundColorAttributeName: kMuted,
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightRegular]}]];
    _metaLabel.attributedText = as;

    _switch.enabled = loaded;
    if (_switch.isOn != on) [_switch setOn:on animated:animated];

    BOOL hasMsg = p.errorMessage.length > 0;
    _msgLabel.text = p.errorMessage;
    _msgLabel.textColor = (p.state == DXPluginStateFailed) ? kRed : kOrange;
    BOOL showRetry = (p.state == DXPluginStateQuarantined);
    BOOL showControls = on && _built;

    self.layer.borderColor = (on ? DXRGBA(50, 213, 131, 0.35) : (p.state == DXPluginStateFailed ? DXRGBA(255, 93, 108, 0.4) : kLine)).CGColor;

    void (^apply)(void) = ^{
        self->_msgLabel.hidden = !hasMsg;
        self->_retry.hidden = !showRetry;
        self->_controls.hidden = !showControls;
    };
    if (animated && self.window) {
        [UIView animateWithDuration:0.25 animations:^{ apply(); [self.window layoutIfNeeded]; }];
    } else {
        apply();
    }
}

@end

/* ======================================================================
 *  DXOverlay
 * ====================================================================== */

@interface DXOverlay () <UIDocumentPickerDelegate>
@end

@implementation DXOverlay {
    BOOL _started, _panelOpen, _dirty, _bannerDismissed;
    DXPassWindow *_window;
    DXRootViewController *_rootVC;
    DXBubble *_mainBubble;
    NSMutableDictionary<NSString *, DXBubble *> *_ownBubbles;
    NSMutableArray<DXCardView *> *_cards;

    UIView *_panel;
    NSLayoutConstraint *_panelW, *_panelH;
    UISegmentedControl *_tabs;
    UIView *_tweakPage, *_logPage, *_bannerWrap;
    UILabel *_bannerLabel, *_emptyLabel, *_statsLabel;
    UIStackView *_listStack;
    UITextView *_logView;

    UIView *_toastBox;
    UILabel *_toastLabel;
    NSInteger _toastGen;
    UIWindow *_prevKey;
}

+ (instancetype)shared {
    static DXOverlay *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[DXOverlay alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _ownBubbles = [NSMutableDictionary dictionary];
        _cards = [NSMutableArray array];
    }
    return self;
}

/* ---------------- Khởi động ---------------- */

- (UIWindowScene *)activeScene {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

- (void)start {
    if (_started) return;
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); return; }
    _started = YES;

    _rootVC = [[DXRootViewController alloc] init];
    __weak DXOverlay *ws = self;
    _rootVC.onLayout = ^{ [ws layoutOverlay]; };

    DXPassWindow *w = nil;
    UIWindowScene *sc = [self activeScene];
    if (sc) w = [[DXPassWindow alloc] initWithWindowScene:sc];
    if (!w) w = [[DXPassWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.windowLevel = UIWindowLevelAlert + 1000;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = _rootVC;
    w.hidden = NO;       /* không makeKey: không cướp focus của game */
    _window = w;

    [self buildMainBubble];
    [self buildPanel];
    [self buildToast];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(loaderChanged) name:DXLoaderDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(appBecameActive) name:UIApplicationDidBecomeActiveNotification object:nil];

    [self loaderChanged];
    DXLOGI("ui", "Overlay đã khởi động");
}

- (void)appBecameActive {
    UIWindowScene *sc = [self activeScene];
    if (sc && _window.windowScene != sc) _window.windowScene = sc;
}

/* ---------------- Bubble chính ---------------- */

- (void)buildMainBubble {
    _mainBubble = [[DXBubble alloc] initWithSize:54 text:@"D" hue:0 main:YES];
    _mainBubble.saveKey = @"main";
    __weak DXOverlay *ws = self;
    _mainBubble.onTap = ^{ [ws openPanel]; };
    [_rootVC.view addSubview:_mainBubble];
    [_mainBubble wake];
}

/* ---------------- Dựng bảng ---------------- */

- (void)buildPanel {
    UIView *root = _rootVC.view;

    _panel = [[UIView alloc] init];
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    _panel.backgroundColor = kPanelBG;
    _panel.layer.cornerRadius = 24;
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = kLine.CGColor;
    _panel.clipsToBounds = YES;
    _panel.hidden = YES;
    _panel.alpha = 0;
    [root addSubview:_panel];
    _panelW = [_panel.widthAnchor constraintEqualToConstant:360];
    _panelH = [_panel.heightAnchor constraintEqualToConstant:520];
    [NSLayoutConstraint activateConstraints:@[
        _panelW, _panelH,
        [_panel.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_panel.centerYAnchor constraintEqualToAnchor:root.centerYAnchor]
    ]];

    /* Header */
    UILabel *logo = [[UILabel alloc] init];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.text = @"D";
    logo.textAlignment = NSTextAlignmentCenter;
    logo.font = [UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
    logo.textColor = UIColor.whiteColor;
    logo.backgroundColor = kAccent;
    logo.layer.cornerRadius = 17;
    logo.clipsToBounds = YES;
    [logo.widthAnchor constraintEqualToConstant:34].active = YES;
    [logo.heightAnchor constraintEqualToConstant:34].active = YES;

    UILabel *t1 = DXLabel(@"DYNEX - Plugin Manager", 15, UIFontWeightSemibold, kText);
    UILabel *t2 = DXLabel(@"Dynamic Execution Manager", 11.5, UIFontWeightRegular, kMuted);
    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[t1, t2]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 2;

    UIButton *close = DXIconButton(@"chevron.down", kText);
    close.backgroundColor = kCard;
    close.layer.cornerRadius = 11;
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[logo, titles, close]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;
    header.layoutMarginsRelativeArrangement = YES;
    header.layoutMargins = UIEdgeInsetsMake(12, 16, 12, 12);

    /* Tabs */
    _tabs = [[UISegmentedControl alloc] initWithItems:@[@"Tweak", @"Nhật ký"]];
    _tabs.selectedSegmentIndex = 0;
    _tabs.selectedSegmentTintColor = kAccent;
    [_tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateSelected];
    [_tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: kMuted} forState:UIControlStateNormal];
    [_tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    UIView *tabsWrap = DXWrap(_tabs, UIEdgeInsetsMake(10, 12, 10, 12), nil);

    /* Trang Tweak */
    UILabel *listTitle = DXLabel(@"DANH SÁCH TWEAK", 11.5, UIFontWeightSemibold, kMuted);
    listTitle.numberOfLines = 1;
    [listTitle setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIButton *add = DXButton(@"+  Nhập", kAccent, UIColor.whiteColor);
    [add addTarget:self action:@selector(tapImport) forControlEvents:UIControlEventTouchUpInside];
    [add.heightAnchor constraintEqualToConstant:32].priority = UILayoutPriorityRequired;
    UIStackView *toolbar = [[UIStackView alloc] initWithArrangedSubviews:@[listTitle, add]];
    toolbar.axis = UILayoutConstraintAxisHorizontal;
    toolbar.alignment = UIStackViewAlignmentCenter;
    toolbar.layoutMarginsRelativeArrangement = YES;
    toolbar.layoutMargins = UIEdgeInsetsMake(2, 16, 6, 16);

    _bannerLabel = DXLabel(@"", 12, UIFontWeightRegular, kText);
    UIButton *bDetail = DXButton(@"Xem chi tiết", DXRGBA(255, 176, 64, 0.22), kText);
    UIButton *bOk = DXButton(@"Đã hiểu", DXRGBA(255, 255, 255, 0.08), kText);
    [bDetail addTarget:self action:@selector(bannerDetails) forControlEvents:UIControlEventTouchUpInside];
    [bOk addTarget:self action:@selector(bannerDismiss) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *bBtns = [[UIStackView alloc] initWithArrangedSubviews:@[bDetail, bOk]];
    bBtns.axis = UILayoutConstraintAxisHorizontal;
    bBtns.spacing = 8;
    bBtns.distribution = UIStackViewDistributionFillEqually;
    UIStackView *bStack = [[UIStackView alloc] initWithArrangedSubviews:@[_bannerLabel, bBtns]];
    bStack.axis = UILayoutConstraintAxisVertical;
    bStack.spacing = 8;
    bStack.layoutMarginsRelativeArrangement = YES;
    bStack.layoutMargins = UIEdgeInsetsMake(12, 12, 12, 12);
    UIView *bBox = DXWrap(bStack, UIEdgeInsetsZero, DXRGBA(255, 176, 64, 0.12));
    bBox.layer.cornerRadius = 12;
    bBox.layer.borderWidth = 1;
    bBox.layer.borderColor = DXRGBA(255, 176, 64, 0.4).CGColor;
    bBox.clipsToBounds = YES;
    _bannerWrap = DXWrap(bBox, UIEdgeInsetsMake(0, 12, 8, 12), nil);
    _bannerWrap.hidden = YES;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = NO;
    [scroll setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisVertical];
    _listStack = [[UIStackView alloc] init];
    _listStack.translatesAutoresizingMaskIntoConstraints = NO;
    _listStack.axis = UILayoutConstraintAxisVertical;
    _listStack.spacing = 8;
    [scroll addSubview:_listStack];
    [NSLayoutConstraint activateConstraints:@[
        [_listStack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:4],
        [_listStack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-12],
        [_listStack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:12],
        [_listStack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-12],
        [_listStack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-24]
    ]];

    UIStackView *page = [[UIStackView alloc] initWithArrangedSubviews:@[toolbar, _bannerWrap, scroll]];
    page.axis = UILayoutConstraintAxisVertical;
    _tweakPage = [[UIView alloc] init];
    _tweakPage.translatesAutoresizingMaskIntoConstraints = NO;
    [_tweakPage addSubview:page];
    DXPin(page, _tweakPage, UIEdgeInsetsZero);

    _emptyLabel = DXLabel(@"Chưa có tweak nào\nNhấn \"+ Nhập\" để thêm file .dylib", 13, UIFontWeightRegular, kMuted);
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.userInteractionEnabled = NO;
    [_tweakPage addSubview:_emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_tweakPage.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_tweakPage.centerYAnchor constant:40],
        [_emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_tweakPage.leadingAnchor constant:24]
    ]];

    /* Trang Nhật ký */
    _logView = [[UITextView alloc] init];
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    _logView.editable = NO;
    _logView.backgroundColor = DXRGBA(15, 15, 19, 1);
    _logView.textColor = kText;
    _logView.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    _logView.layer.cornerRadius = 12;
    _logView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    UIButton *l1 = DXButton(@"Làm mới", DXRGBA(124, 92, 255, 0.18), kText);
    UIButton *l2 = DXButton(@"Sao chép", DXRGBA(124, 92, 255, 0.18), kText);
    UIButton *l3 = DXButton(@"Xoá", DXRGBA(255, 93, 108, 0.2), kText);
    [l1 addTarget:self action:@selector(logRefresh) forControlEvents:UIControlEventTouchUpInside];
    [l2 addTarget:self action:@selector(logCopy) forControlEvents:UIControlEventTouchUpInside];
    [l3 addTarget:self action:@selector(logClear) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *lBtns = [[UIStackView alloc] initWithArrangedSubviews:@[l1, l2, l3]];
    lBtns.axis = UILayoutConstraintAxisHorizontal;
    lBtns.spacing = 8;
    lBtns.distribution = UIStackViewDistributionFillEqually;
    UIStackView *lp = [[UIStackView alloc] initWithArrangedSubviews:@[_logView, lBtns]];
    lp.axis = UILayoutConstraintAxisVertical;
    lp.spacing = 8;
    lp.layoutMarginsRelativeArrangement = YES;
    lp.layoutMargins = UIEdgeInsetsMake(4, 12, 12, 12);
    _logPage = [[UIView alloc] init];
    _logPage.translatesAutoresizingMaskIntoConstraints = NO;
    _logPage.hidden = YES;
    [_logPage addSubview:lp];
    DXPin(lp, _logPage, UIEdgeInsetsZero);

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content setContentHuggingPriority:UILayoutPriorityDefaultLow - 10 forAxis:UILayoutConstraintAxisVertical];
    [content setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [content addSubview:_tweakPage];
    [content addSubview:_logPage];
    DXPin(_tweakPage, content, UIEdgeInsetsZero);
    DXPin(_logPage, content, UIEdgeInsetsZero);

    /* Footer */
    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = kGreen;
    dot.layer.cornerRadius = 3.5;
    [dot.widthAnchor constraintEqualToConstant:7].active = YES;
    [dot.heightAnchor constraintEqualToConstant:7].active = YES;
    UILabel *core = DXLabel(@"DYNEX Core v1.0", 11, UIFontWeightSemibold, kText);
    core.numberOfLines = 1;
    [core setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _statsLabel = DXLabel(@"", 11, UIFontWeightRegular, kMuted);
    _statsLabel.numberOfLines = 1;
    _statsLabel.textAlignment = NSTextAlignmentRight;
    _statsLabel.adjustsFontSizeToFitWidth = YES;
    _statsLabel.minimumScaleFactor = 0.7;
    [_statsLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *fs = [[UIStackView alloc] initWithArrangedSubviews:@[dot, core, _statsLabel]];
    fs.axis = UILayoutConstraintAxisHorizontal;
    fs.alignment = UIStackViewAlignmentCenter;
    fs.spacing = 6;
    UIView *footer = DXWrap(fs, UIEdgeInsetsMake(10, 16, 10, 16), DXRGBA(0, 0, 0, 0.35));

    UIStackView *main = [[UIStackView alloc] initWithArrangedSubviews:@[header, DXLine(), tabsWrap, content, DXLine(), footer]];
    main.axis = UILayoutConstraintAxisVertical;
    [_panel addSubview:main];
    DXPin(main, _panel, UIEdgeInsetsZero);
}

- (void)buildToast {
    UIView *root = _rootVC.view;
    _toastLabel = DXLabel(@"", 13, UIFontWeightRegular, kText);
    _toastLabel.textAlignment = NSTextAlignmentCenter;
    _toastBox = DXWrap(_toastLabel, UIEdgeInsetsMake(10, 16, 10, 16), DXRGBA(35, 35, 43, 0.96));
    _toastBox.layer.cornerRadius = 12;
    _toastBox.clipsToBounds = YES;
    _toastBox.alpha = 0;
    _toastBox.userInteractionEnabled = NO;
    [root addSubview:_toastBox];
    [NSLayoutConstraint activateConstraints:@[
        [_toastBox.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_toastBox.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [_toastBox.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor multiplier:0.9]
    ]];
}

- (void)toast:(NSString *)text {
    if (!text.length) return;
    _toastLabel.text = text;
    _toastGen++;
    NSInteger gen = _toastGen;
    [UIView animateWithDuration:0.2 animations:^{ self->_toastBox.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != self->_toastGen) return;
        [UIView animateWithDuration:0.3 animations:^{ self->_toastBox.alpha = 0; }];
    });
}

/* ---------------- Bố cục ---------------- */

- (void)layoutOverlay {
    if (!_started) return;
    UIView *root = _rootVC.view;
    UIEdgeInsets in = root.safeAreaInsets;
    CGFloat w = fmin(380, root.bounds.size.width - in.left - in.right - 24);
    CGFloat h = fmin(560, root.bounds.size.height - in.top - in.bottom - 24);
    w = fmax(w, 240);
    h = fmax(h, 220);
    if (fabs(_panelW.constant - w) > 0.5) _panelW.constant = w;
    if (fabs(_panelH.constant - h) > 0.5) _panelH.constant = h;

    [_mainBubble applyFraction];
    for (DXBubble *b in _ownBubbles.allValues) [b applyFraction];
}

/* ---------------- Mở / đóng bảng ---------------- */

- (void)openPanel {
    if (_panelOpen) return;
    _panelOpen = YES;
    if (_dirty) { [self reconcileCards]; }
    [self updateBanner];
    [self updateStats];
    if (_tabs.selectedSegmentIndex == 1) [self refreshLog];

    _mainBubble.hidden = YES;
    _panel.hidden = NO;
    _panel.alpha = 0;
    _panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_panel.alpha = 1;
        self->_panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)closePanel {
    if (!_panelOpen) return;
    _panelOpen = NO;
    _mainBubble.hidden = NO;
    [_mainBubble wake];
    [UIView animateWithDuration:0.18 animations:^{
        self->_panel.alpha = 0;
        self->_panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } completion:^(BOOL finished) {
        if (!self->_panelOpen) self->_panel.hidden = YES;
    }];
}

- (void)tabChanged:(UISegmentedControl *)s {
    BOOL log = (s.selectedSegmentIndex == 1);
    _tweakPage.hidden = log;
    _logPage.hidden = !log;
    if (log) [self refreshLog];
}

/* ---------------- Đồng bộ với Loader ---------------- */

- (void)loaderChanged {
    [self reconcileBubbles];
    [self updateStats];
    if (_panelOpen) {
        [self reconcileCards];
        [self updateBanner];
    } else {
        _dirty = YES;
    }
}

- (void)reconcileCards {
    _dirty = NO;
    NSArray<DXPlugin *> *plugins = [DXLoader shared].plugins;

    for (DXCardView *c in [_cards copy]) {
        if (![plugins containsObject:c.plugin]) {
            [_cards removeObject:c];
            [UIView animateWithDuration:0.2 animations:^{ c.alpha = 0; } completion:^(BOOL f) { [c removeFromSuperview]; }];
        }
    }

    NSUInteger idx = 0;
    for (DXPlugin *p in plugins) {
        DXCardView *card = nil;
        for (DXCardView *c in _cards) if (c.plugin == p) { card = c; break; }
        if (!card) {
            card = [[DXCardView alloc] initWithPlugin:p];
            __weak DXOverlay *ws = self;
            card.onRemove = ^(DXPlugin *plugin) { [ws confirmRemove:plugin]; };
            card.onOpenOwnUI = ^(DXPlugin *plugin) {
                [ws closePanel];
                [[DXLoader shared] openUIForPlugin:plugin];
            };
            [_cards addObject:card];
            [_listStack insertArrangedSubview:card atIndex:MIN(idx, _listStack.arrangedSubviews.count)];
        } else {
            [card refresh];
        }
        idx++;
    }
    _emptyLabel.hidden = (plugins.count > 0);
}

- (void)reconcileBubbles {
    NSArray<DXPlugin *> *plugins = [DXLoader shared].plugins;
    NSMutableDictionary<NSString *, DXPlugin *> *want = [NSMutableDictionary dictionary];
    for (DXPlugin *p in plugins) {
        if (p.ownUI && p.state == DXPluginStateLoaded && p.enabled) want[p.fileName] = p;
    }

    for (NSString *key in [_ownBubbles.allKeys copy]) {
        if (want[key]) continue;
        DXBubble *b = _ownBubbles[key];
        [_ownBubbles removeObjectForKey:key];
        [UIView animateWithDuration:0.2 animations:^{ b.transform = CGAffineTransformMakeScale(0.01, 0.01); b.alpha = 0; }
                         completion:^(BOOL f) { [b removeFromSuperview]; }];
    }

    for (NSString *key in want) {
        if (_ownBubbles[key]) continue;
        DXPlugin *p = want[key];
        DXBubble *b = [[DXBubble alloc] initWithSize:46 text:p.bubbleText hue:p.hue main:NO];
        b.saveKey = [@"own." stringByAppendingString:key];
        [b setDefaultFractionX:0.05 y:fmin(0.28 + 0.13 * _ownBubbles.count, 0.85)];
        b.onTap = ^{ [[DXLoader shared] openUIForPlugin:p]; };
        [_rootVC.view addSubview:b];
        [b applyFraction];
        _ownBubbles[key] = b;
        b.transform = CGAffineTransformMakeScale(0.01, 0.01);
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:0
                         animations:^{ b.transform = CGAffineTransformIdentity; } completion:nil];
        [b wake];
    }
}

- (void)updateStats {
    NSUInteger loaded = 0, running = 0;
    DXLoader *ld = [DXLoader shared];
    for (DXPlugin *p in ld.plugins) {
        if (p.state == DXPluginStateLoaded) { loaded++; if (p.enabled) running++; }
    }
    _statsLabel.text = [NSString stringWithFormat:@"Đã nạp: %lu · Chạy: %lu · Bubble: %lu%@",
                        (unsigned long)loaded, (unsigned long)running, (unsigned long)_ownBubbles.count,
                        ld.loading ? @" · đang nạp…" : @""];
    [_mainBubble setCount:running];
}

- (void)updateBanner {
    NSString *text = [DXLoader shared].recoveryNote;
    if (!text.length && _previousReport.length) {
        text = @"Lần chạy trước kết thúc bất thường. Xem chi tiết ở tab Nhật ký.";
    }
    _bannerLabel.text = text ?: @"";
    _bannerWrap.hidden = !(text.length && !_bannerDismissed);
}

- (void)bannerDetails {
    _tabs.selectedSegmentIndex = 1;
    [self tabChanged:_tabs];
}

- (void)bannerDismiss {
    _bannerDismissed = YES;
    [self updateBanner];
}

/* ---------------- Nhật ký ---------------- */

- (void)refreshLog {
    NSMutableString *s = [NSMutableString string];
    if (_previousReport.length) {
        [s appendFormat:@"=== SỰ CỐ LẦN CHẠY TRƯỚC ===\n%@\n\n=== NHẬT KÝ ===\n", _previousReport];
    }
    NSString *tail = DXLogReadTail(24 * 1024);
    [s appendString:tail.length ? tail : @"(nhật ký trống)\n"];
    _logView.text = s;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger n = self->_logView.text.length;
        if (n > 0) [self->_logView scrollRangeToVisible:NSMakeRange(n - 1, 1)];
    });
}

- (void)logRefresh { [self refreshLog]; }

- (void)logCopy {
    UIPasteboard.generalPasteboard.string = _logView.text ?: @"";
    [self toast:@"Đã sao chép nhật ký"];
}

- (void)logClear {
    [self confirmTitle:@"Xoá nhật ký?" message:@"Xoá toàn bộ nhật ký và báo cáo crash đã lưu." action:@"Xoá" destructive:YES handler:^{
        DXLogClear();
        self->_previousReport = nil;
        [self updateBanner];
        [self refreshLog];
        [self toast:@"Đã xoá nhật ký"];
    }];
}

/* ---------------- Hộp thoại ---------------- */

- (void)confirmTitle:(NSString *)title message:(NSString *)msg action:(NSString *)actionTitle
         destructive:(BOOL)destructive handler:(void (^)(void))handler {
    if (_rootVC.presentedViewController) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:actionTitle
                                          style:(destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault)
                                        handler:^(UIAlertAction *x) { handler(); }]];
    [_rootVC presentViewController:a animated:YES completion:nil];
}

- (void)confirmRemove:(DXPlugin *)p {
    NSString *name = p.state == DXPluginStateLoaded ? p.name : p.fileName;
    [self confirmTitle:[NSString stringWithFormat:@"Xoá %@?", name]
               message:@"File sẽ bị xoá. Phần đã nạp trong bộ nhớ chỉ giải phóng khi khởi động lại game."
                action:@"Xoá" destructive:YES handler:^{
        [[DXLoader shared] removePlugin:p];
        [self toast:@"Đã xoá tweak"];
    }];
}

/* ---------------- Nhập file ---------------- */

- (void)restoreKeyWindow {
    UIWindow *k = _prevKey;
    _prevKey = nil;
    if (k) [k makeKeyWindow];
}

- (void)tapImport {
    if (_rootVC.presentedViewController) return;
    UIDocumentPickerViewController *pk =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"] inMode:UIDocumentPickerModeImport];
    pk.delegate = self;
    pk.allowsMultipleSelection = YES;
    /* Bộ chọn file cần cửa sổ key để bàn phím tìm kiếm hoạt động; trả lại cho game ngay sau đó */
    _prevKey = DXFindGameWindow(_window, YES);
    [_window makeKeyWindow];
    [_rootVC presentViewController:pk animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self restoreKeyWindow];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self restoreKeyWindow];
    [self importURLs:urls index:0 ok:0 firstError:nil];
}

- (void)importURLs:(NSArray<NSURL *> *)urls index:(NSUInteger)i ok:(NSUInteger)ok firstError:(NSString *)err {
    if (i >= urls.count) {
        if (ok && !err) [self toast:[NSString stringWithFormat:@"Đã nhập %lu tweak (đang đóng băng)", (unsigned long)ok]];
        else if (ok && err) [self toast:[NSString stringWithFormat:@"Nhập %lu tweak. Lỗi: %@", (unsigned long)ok, err]];
        else if (err) [self toast:err];
        return;
    }
    [[DXLoader shared] importFileAtURL:urls[i] completion:^(NSString *e) {
        [self importURLs:urls index:i + 1 ok:ok + (e ? 0 : 1) firstError:(err ?: e)];
    }];
}

@end
