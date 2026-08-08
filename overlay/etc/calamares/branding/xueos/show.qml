import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    Timer {
        interval: 15000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }
    Slide {
        Image {
            anchors.centerIn: parent
            id: image1
            fillMode: Image.PreserveAspectFit
            smooth: true
            width: parent.width * 0.8
            height: parent.height * 0.8
            source: "slide1.png"
        }
    }
    Slide {
        Image {
            anchors.centerIn: parent
            id: image2
            fillMode: Image.PreserveAspectFit
            smooth: true
            width: parent.width * 0.8
            height: parent.height * 0.8
            source: "slide2.png"
        }
    }
    Slide {
        Image {
            anchors.centerIn: parent
            id: image3
            fillMode: Image.PreserveAspectFit
            smooth: true
            width: parent.width * 0.8
            height: parent.height * 0.8
            source: "slide3.png"
        }
    }
}
