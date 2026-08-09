// Copyright (c) 2010-2026 Contributors to the openHAB project
//
// See the NOTICE file(s) distributed with this work for additional
// information.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0
//
// SPDX-License-Identifier: EPL-2.0

@testable import openHAB
import OpenHABCore
import Testing

/// Structure the CarPlay scene derives from a sitemap page: which widgets it can render,
/// how frames become sections, and how a stream failure is paced.
@MainActor
struct CarPlaySitemapStructureTests {
    // MARK: - Fixtures

    let delegate = CarPlaySceneDelegate()

    func page(widgets: [OpenHABWidget]) -> OpenHABPage {
        // Flattens on the way in, exactly as a page decoded from the server does.
        OpenHABPage(pageId: "p", title: "P", link: "", leaf: false, widgets: widgets, icon: "")
    }

    func item() -> OpenHABItem {
        OpenHABItem(
            name: "I", type: "Switch", state: "ON", link: "", label: "I",
            groupType: nil, stateDescription: nil, commandDescription: nil,
            members: [], category: nil, options: nil
        )
    }

    func frame(id: String, label: String, children: [OpenHABWidget]) -> OpenHABWidget {
        widget(id: id, label: label, type: .frame, item: nil, children: children)
    }

    func switchWidget(id: String, label: String) -> OpenHABWidget {
        widget(id: id, label: label, type: .switchWidget, item: item())
    }

    func widget(id: String,
                label: String,
                type: OpenHABWidget.WidgetType,
                item: OpenHABItem?,
                children: [OpenHABWidget] = []) -> OpenHABWidget {
        OpenHABWidget(
            widgetId: id, label: label, icon: "text", type: type,
            url: nil, period: nil, minValue: nil, maxValue: nil, step: nil,
            refresh: nil, height: nil, isLeaf: nil, iconColor: nil,
            labelColor: nil, valueColor: nil, service: nil, state: nil,
            text: nil, legend: nil, inputHint: nil, encoding: nil,
            item: item, linkedPage: nil, mappings: [], widgets: children,
            visibility: true, switchSupport: nil, forceAsItem: nil,
            labelSource: .sitemapDefinition, releaseOnly: nil
        )
    }

    // MARK: - Frames

    /// `OpenHABPage` depth-first flattens its tree, so a frame sits in the same array as the
    /// children that name it in `parentWidgetId`. Walking into `widget.widgets` as well
    /// counted every child twice and doubled the whole UI.
    @Test
    func framesBecomeSectionsWithoutDuplicatingChildren() {
        let page = page(widgets: [
            frame(id: "1_0", label: "All Lights", children: [
                switchWidget(id: "1_00", label: "All Lights ON/OFF")
            ]),
            frame(id: "1_1", label: "Floors", children: [
                switchWidget(id: "1_10", label: "First Floor"),
                switchWidget(id: "1_11", label: "Second Floor")
            ])
        ])

        let sections = delegate.widgetSections(of: page.widgets)

        #expect(sections.count == 2)
        #expect(sections.map(\.header) == ["All Lights", "Floors"])
        #expect(sections.map(\.widgets.count) == [1, 2])
        #expect(sections.flatMap { $0.widgets.map(\.widgetId) } == ["1_00", "1_10", "1_11"])
    }

    @Test
    func widgetsOutsideAnyFrameFormAnUnheadedSection() {
        let page = page(widgets: [
            switchWidget(id: "1_0", label: "Porch"),
            frame(id: "1_1", label: "Kitchen", children: [switchWidget(id: "1_10", label: "Island")])
        ])

        let sections = delegate.widgetSections(of: page.widgets)

        #expect(sections.count == 2)
        #expect(sections[0].header == nil)
        #expect(sections[0].widgets.map(\.widgetId) == ["1_0"])
        #expect(sections[1].header == "Kitchen")
    }

    @Test
    func frameWithNoRenderableChildrenIsOmitted() {
        let page = page(widgets: [
            frame(id: "1_0", label: "Cameras", children: [
                widget(id: "1_00", label: "Front Door", type: .image, item: nil)
            ])
        ])

        #expect(delegate.widgetSections(of: page.widgets).isEmpty)
    }

    @Test
    func emptyFrameLabelYieldsNoHeader() {
        let page = page(widgets: [
            frame(id: "1_0", label: "", children: [switchWidget(id: "1_00", label: "Lamp")])
        ])

        #expect(delegate.widgetSections(of: page.widgets).first?.header == nil)
    }

    // MARK: - Compatibility

    @Test
    func rendersSwitchesSetpointsSlidersSelectionsAndValues() {
        for type in [OpenHABWidget.WidgetType.switchWidget, .setpoint, .slider, .selection, .text] {
            #expect(
                delegate.isCompatible(widget(id: "w", label: "W", type: type, item: item())),
                "expected \(type) to be renderable"
            )
        }
    }

    @Test
    func skipsWidgetsWithNoItemAndUnsupportedTypes() {
        #expect(!delegate.isCompatible(widget(id: "w", label: "W", type: .switchWidget, item: nil)))
        for type in [OpenHABWidget.WidgetType.image, .chart, .webview, .frame] {
            #expect(
                !delegate.isCompatible(widget(id: "w", label: "W", type: type, item: item())),
                "expected \(type) to be skipped"
            )
        }
    }

    // MARK: - Retry pacing

    @Test
    func retryBacksOffAndCaps() {
        #expect(CarPlaySceneDelegate.retryDelay(failures: 0) == 2)
        #expect(CarPlaySceneDelegate.retryDelay(failures: 1) == 2)
        #expect(CarPlaySceneDelegate.retryDelay(failures: 2) == 4)
        #expect(CarPlaySceneDelegate.retryDelay(failures: 3) == 8)
        #expect(CarPlaySceneDelegate.retryDelay(failures: 20) == 30)
    }

    @Test
    func rollershutterFallbackCarriesTheThreeStandardCommands() {
        #expect(CarPlaySceneDelegate.rollershutterMappings.map(\.command) == ["UP", "STOP", "DOWN"])
    }
}
