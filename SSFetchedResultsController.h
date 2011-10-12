//
//  SSFetchedResultsController.h
//  SSFetchedResultsController
//
//  Created by Sam Soffes on 10/12/11.
//  Copyright (c) 2011 Sam Soffes. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@protocol SSFetchedResultsControllerDelegate;

@interface SSFetchedResultsController : NSFetchedResultsController <NSFetchedResultsControllerDelegate>

@property (nonatomic, assign) id <SSFetchedResultsControllerDelegate> safeDelegate;

@end

@protocol SSFetchedResultsControllerDelegate <NSFetchedResultsControllerDelegate, NSObject>
@optional

- (void)controllerDidMakeUnsafeChanges:(NSFetchedResultsController *)controller;

@end
