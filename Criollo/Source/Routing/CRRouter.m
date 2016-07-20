//
//  CRRoutingCenter.m
//  Criollo
//
//  Created by Cătălin Stan on 19/07/16.
//  Copyright © 2016 Cătălin Stan. All rights reserved.
//

#import "CRRouter.h"
#import "CRRoute.h"
#import "CRServer.h"
#import "CRMessage.h"
#import "CRMessage_Internal.h"
#import "CRRequest.h"
#import "CRRequest_Internal.h"
#import "CRResponse.h"
#import "CRResponse_Internal.h"

NS_ASSUME_NONNULL_BEGIN

@interface CRRouter ()

@property (nonatomic, strong, readonly) NSMutableDictionary<NSString*, NSMutableArray<CRRoute *> *> * routes;
@property (nonatomic, strong, readonly) NSMutableArray<NSString *> * recursiveMatchRoutePathPrefixes;

@end

NS_ASSUME_NONNULL_END

@implementation CRRouter

+ (CRRouteBlock)errorHandlingBlockWithStatus:(NSUInteger)statusCode error:(NSError *)error {
    return ^(CRRequest *request, CRResponse *response, CRRouteCompletionBlock completionHandler) {
        [response setStatusCode:statusCode description:nil];
        [response setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-type"];

        NSMutableString* responseString = [NSMutableString string];

#if DEBUG
        NSError* err;
        if (error == nil) {
            NSMutableDictionary* mutableUserInfo = [NSMutableDictionary dictionaryWithCapacity:2];
            NSString* errorDescription;
            switch (statusCode) {
                case 404:
                    errorDescription = [NSString stringWithFormat:NSLocalizedString(@"No routes defined for “%@%@%@”",), NSStringFromCRHTTPMethod(request.method), request.URL.path, [request.URL.path hasSuffix:CRPathSeparator] ? @"" : CRPathSeparator];
                    break;
            }
            if ( errorDescription ) {
                mutableUserInfo[NSLocalizedDescriptionKey] = errorDescription;
            }
            mutableUserInfo[NSURLErrorFailingURLErrorKey] = request.URL;
            err = [NSError errorWithDomain:CRServerErrorDomain code:statusCode userInfo:mutableUserInfo];
        } else {
            err = error;
        }

        // Error details
        [responseString appendFormat:@"%@ %lu\n%@\n", err.domain, (long)err.code, err.localizedDescription];

        // Error user-info
        if ( err.userInfo.count > 0 ) {
            [responseString appendString:@"\nUser Info\n"];
            [err.userInfo enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
                [responseString appendFormat:@"%@: %@\n", key, obj];
            }];
        }

        // Stack trace
        [responseString appendString:@"\nStack Trace\n"];
        [[NSThread callStackSymbols] enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            [responseString appendFormat:@"%@\n", obj];
        }];
#else
        [responseString appendFormat:@"Cannot %@ %@", NSStringFromCRHTTPMethod(request.method), request.URL.path];
#endif

        [response setValue:@(responseString.length).stringValue forHTTPHeaderField:@"Content-Length"];
        [response sendString:responseString];
        
        completionHandler();
    };
}

- (instancetype)init {
    self = [super init];
    if ( self != nil ) {
        _routes = [NSMutableDictionary dictionary];
        _recursiveMatchRoutePathPrefixes = [NSMutableArray array];
        _notFoundBlock = [CRRouter errorHandlingBlockWithStatus:404 error:nil];
    }
    return self;
}

#pragma mark - Block Routes

- (void)addBlock:(CRRouteBlock)block {
    [self addBlock:block forPath:nil HTTPMethod:CRHTTPMethodAll recursive:NO];
}

- (void)addBlock:(CRRouteBlock)block forPath:(NSString*)path {
    [self addBlock:block forPath:path HTTPMethod:CRHTTPMethodAll recursive:NO];
}

- (void)addBlock:(CRRouteBlock)block forPath:(NSString *)path HTTPMethod:(CRHTTPMethod)method {
    [self addBlock:block forPath:path HTTPMethod:method recursive:NO];
}

- (void)addBlock:(CRRouteBlock)block forPath:(NSString *)path HTTPMethod:(CRHTTPMethod)method recursive:(BOOL)recursive {
    CRRoute* route = [CRRoute routeWithBlock:block];
    [self addRoute:route forPath:path HTTPMethod:method recursive:recursive];
}

#pragma mark - Route Controller Routes

- (void)addController:(__unsafe_unretained Class)controllerClass forPath:(NSString *)path {
    [self addController:controllerClass forPath:path HTTPMethod:CRHTTPMethodAll recursive:NO];
}

- (void)addController:(__unsafe_unretained Class)controllerClass forPath:(NSString *)path HTTPMethod:(CRHTTPMethod)method {
    [self addController:controllerClass forPath:path HTTPMethod:method recursive:NO];
}

- (void)addController:(__unsafe_unretained Class)controllerClass forPath:(NSString *)path HTTPMethod:(CRHTTPMethod)method recursive:(BOOL)recursive {
    CRRoute* route = [CRRoute routeWithControllerClass:controllerClass prefix:path];
    [self addRoute:route forPath:path HTTPMethod:method recursive:recursive];
}

#pragma mark - View Controller Routes

- (void)addViewController:(__unsafe_unretained Class)viewControllerClass withNibName:(NSString *)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil forPath:(NSString *)path {
    [self addViewController:viewControllerClass withNibName:nibNameOrNil bundle:nibBundleOrNil forPath:path HTTPMethod:CRHTTPMethodAll recursive:NO];
}

- (void)addViewController:(__unsafe_unretained Class)viewControllerClass withNibName:(NSString *)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil forPath:(NSString *)path HTTPMethod:(CRHTTPMethod)method {
    [self addViewController:viewControllerClass withNibName:nibNameOrNil bundle:nibBundleOrNil forPath:path HTTPMethod:method recursive:NO];
}

- (void)addViewController:(__unsafe_unretained Class)viewControllerClass withNibName:(NSString *)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil forPath:(NSString *)path HTTPMethod:(CRHTTPMethod)method recursive:(BOOL)recursive {
    CRRoute* route = [CRRoute routeWithViewControllerClass:viewControllerClass nibName:nibNameOrNil bundle:nibBundleOrNil prefix:path];
    [self addRoute:route forPath:path HTTPMethod:method recursive:recursive];
}

#pragma mark - General Routes

- (void)addRoute:(CRRoute*)route forPath:(NSString *)path HTTPMethod:(CRHTTPMethod)method recursive:(BOOL)recursive {
    NSArray<NSString*>* methods;

    if ( method == CRHTTPMethodAll ) {
        methods = [CRMessage acceptedHTTPMethods];
    } else {
        methods = @[NSStringFromCRHTTPMethod(method), NSStringFromCRHTTPMethod(CRHTTPMethodHead)];
    }

    if ( path == nil ) {
        path = CRPathAnyPath;
        recursive = NO;
    }

    if ( ![path isEqualToString:CRPathAnyPath] && ![path hasSuffix:CRPathSeparator] ) {
        path = [path stringByAppendingString:CRPathSeparator];
    }

    [methods enumerateObjectsUsingBlock:^(NSString * _Nonnull method, NSUInteger idx, BOOL * _Nonnull stop) {

        NSString* routePath = [method stringByAppendingString:path];

        if ( ![self.routes[routePath] isKindOfClass:[NSMutableArray class]] ) {
            NSMutableArray<CRRoute*>* parentRoutes = [NSMutableArray array];

            // Add the "*" routes
            NSString* anyPathRoutePath = [method stringByAppendingString:CRPathAnyPath];
            if ( self.routes[anyPathRoutePath] != nil ) {
                [parentRoutes addObjectsFromArray:self.routes[anyPathRoutePath]];
            }

            self.routes[routePath] = parentRoutes;
        }

        [self.routes[routePath] addObject:route];

        // If the route should be executed on all paths, add it accordingly
        if ( [path isEqualToString:CRPathAnyPath] ) {
            [self.routes enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSMutableArray<CRRoute *> * _Nonnull obj, BOOL * _Nonnull stop) {
                if ( ![obj.lastObject isEqual:route] ) {
                    [obj addObject:route];
                }
            }];
        }

        // If the route is recursive add it to the array
        if ( recursive ) {
            [self.recursiveMatchRoutePathPrefixes addObject:routePath];
        }
    }];
}

- (NSArray<CRRoute*>*)routesForPath:(NSString*)path HTTPMethod:(CRHTTPMethod)method {
    if ( path == nil ) {
        path = @"";
    }

    if ( ![path hasSuffix:CRPathSeparator] ) {
        path = [path stringByAppendingString:CRPathSeparator];
    }
    path = [NSStringFromCRHTTPMethod(method) stringByAppendingString:path];

    __block BOOL shouldRecursivelyMatchRoutePathPrefix = NO;
    [self.recursiveMatchRoutePathPrefixes enumerateObjectsUsingBlock:^(NSString * _Nonnull recursiveMatchRoutePathPrefix, NSUInteger idx, BOOL * _Nonnull stop) {
        if ( [path hasPrefix:recursiveMatchRoutePathPrefix] ) {
            shouldRecursivelyMatchRoutePathPrefix = YES;
            *stop = YES;
        }
    }];

    NSArray<CRRoute*>* routes;
    while ( routes.count == 0 ) {
        routes = self.routes[path];
        if ( !shouldRecursivelyMatchRoutePathPrefix) {
            break;
        }
        path = [[path stringByDeletingLastPathComponent] stringByAppendingString:CRPathSeparator];
    }
    
    return routes;
}

- (void)executeRoutes:(NSArray<CRRoute *> *)routes forRequest:(CRRequest *)request response:(CRResponse *)response {
    [self executeRoutes:routes forRequest:request response:response withNotFoundBlock:nil];
}

- (void)executeRoutes:(NSArray<CRRoute *> *)routes forRequest:(CRRequest *)request response:(CRResponse *)response withNotFoundBlock:(CRRouteBlock)notFoundBlock {
    if ( !notFoundBlock ) {
        notFoundBlock = [CRRouter errorHandlingBlockWithStatus:404 error:nil];
    }

    if ( routes.count == 0 ) {
        routes = @[[CRRoute routeWithBlock:notFoundBlock]];
    }

    __block BOOL shouldStopExecutingBlocks = NO;
    __block NSUInteger currentRouteIndex = 0;
    dispatch_block_t completionHandler = ^{
        shouldStopExecutingBlocks = NO;
        currentRouteIndex++;
    };
    while (!shouldStopExecutingBlocks && currentRouteIndex < routes.count ) {
        shouldStopExecutingBlocks = YES;
        CRRouteBlock block = routes[currentRouteIndex].block;
        block(request, response, completionHandler);
    }
}

@end
