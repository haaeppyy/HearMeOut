
# Hear Me Out 🎙️

### Making conventional phone calls accessible to everyone.

**Hear Me Out** is an accessibility-focused iOS application that aims to bridge the communication gap experienced by Deaf, Hard-of-Hearing (HoH), and non-speaking individuals.

Conventional phone calls are primarily built around spoken communication, assuming that both participants can hear and speak. While this works for people without hearing or speaking disabilities, it creates barriers for individuals who cannot fully participate in voice-based conversations.

Hear Me Out introduces a communication layer that combines **Text-to-Speech (TTS)** and **Speech-to-Text (STT)** to make voice calling more inclusive.

Our goal is simple: enable people to participate in phone conversations independently, without relying on interpreters or third-party assistance.

---

## 🚨 The Problem

Conventional calling systems are designed with hearing and speaking as their default requirements.

For people with hearing or speaking disabilities, this creates challenges:

- Individuals who cannot speak may be unable to communicate verbally during calls.
- Individuals who cannot hear may be unable to understand the other participant.
- Individuals with both hearing and speaking disabilities may face barriers in both directions.
- Existing alternatives may require third-party assistance or separate communication services.

Although text messaging provides an alternative, it does not offer the same real-time conversational experience as a phone call.

**The problem isn't the inability to communicate. It's the lack of accessibility in conventional calling systems.**

---

## 💡 Our Solution

Hear Me Out introduces a two-way translation system that connects text and speech during a call.

It enables users to communicate through:

**1. Text-to-Speech (TTS)**

Users can type their messages, which are converted into audible speech using customizable synthetic voices.

**2. Speech-to-Text (STT)**

The other participant's spoken responses are transcribed into text and displayed as live captions.

By combining these technologies, Hear Me Out allows users to participate in voice conversations using the communication method that works best for them.

---

## 👥 Target Users

Hear Me Out considers four primary communication profiles:

| User Profile | Hearing | Speaking |
|---|---|---|
| Type 1 | Can hear | Can speak |
| Type 2 | Can hear | Cannot speak |
| Type 3 | Cannot hear | Can speak |
| Type 4 | Cannot hear | Cannot speak |

The application aims to accommodate different combinations of hearing and speaking abilities through flexible communication modes.

---

# 🚀 Version 1 — VoIP-to-VoIP Calling

**Current Development Focus**

Version 1 focuses on establishing the core communication experience through internet-based calling (VoIP).

Rather than immediately integrating conventional telephone networks, the initial version enables communication between two users through the application itself.

### Core Features

**1. VoIP-to-VoIP Calling**
- Internet-based calling between Hear Me Out users.
- Real-time audio communication.
- An in-app calling interface.

**2. Text-to-Speech (TTS)**
- Converts typed messages into spoken audio.
- Uses Sarvam AI's Text-to-Speech API.
- Allows users to select from available voice options.
- Enables non-speaking users to communicate through synthetic speech.

**3. Speech-to-Text (STT)**
- Converts incoming spoken audio into text.
- Uses Sarvam AI's Speech-to-Text capabilities.
- Displays transcribed speech as captions during calls.
- Helps Deaf and Hard-of-Hearing users understand spoken responses.

**4. Custom Voice Selection**
- Users can select their preferred synthetic voice.
- Voice selection provides a more personalized communication experience.
- The selected voice is used when generating spoken messages.

**5. Accessibility-Focused Calling Interface**
- Integrated calling and text input interface.
- Live transcription display.
- Simple communication controls.
- Designed around different hearing and speaking capabilities.

### Version 1 Communication Workflow

**Outgoing Communication**

1. The user types a message.
2. The text is sent to Sarvam AI's TTS API.
3. Sarvam generates speech using the selected voice.
4. The generated audio is transmitted to the other participant through the VoIP connection.

**Incoming Communication**

1. The other participant speaks during the call.
2. Incoming audio is processed by the STT system.
3. Sarvam AI transcribes the speech into text.
4. The resulting transcription is displayed to the user.

---

## 🔌 Technology Stack

| Technology | Purpose |
|---|---|
| Swift | Primary programming language |
| SwiftUI | iOS application interface |
| Xcode | iOS development environment |
| Sarvam AI API | Text-to-Speech and Speech-to-Text |
| VoIP Infrastructure | Internet-based calling |
| Supabase | Backend services and data management |

*Additional infrastructure and services may be integrated as development progresses.*

---

# 📞 Next Goal — PSTN Integration

While Version 1 establishes communication between Hear Me Out users through VoIP, the next major milestone is integrating **PSTN (Public Switched Telephone Network)** connectivity.

Currently, conventional phone calls allow people to communicate using their regular mobile or landline numbers without requiring both participants to use the same application.

Our long-term goal is to bring this capability to Hear Me Out.

### What PSTN Integration Will Enable

- Hear Me Out users will be able to call regular mobile and landline numbers.
- People receiving calls will not necessarily need the Hear Me Out application.
- Text-to-Speech and Speech-to-Text will act as an accessibility layer over conventional phone calls.
- Users will be able to communicate with people outside the application's ecosystem.

### Planned Infrastructure

Potential technologies being explored include:

- **Exotel:** SIP trunking and PSTN connectivity.
- **Agora:** Real-time audio communication and telephony integration.

PSTN integration is a future development goal and is not part of the initial VoIP-only release.

---

## 🏗️ Development Roadmap

| Phase | Focus | Status |
|---|---|---|
| Version 1 | VoIP-to-VoIP calling | In Development |
| Version 1 | Sarvam AI TTS integration | In Development |
| Version 1 | Sarvam AI STT integration | In Development |
| Version 1 | Custom voice selection | In Development |
| Version 2 | PSTN connectivity | Planned |
| Future | Multilingual communication | Planned |
| Future | Expanded accessibility features | Planned |

---

## 🌱 Our Vision

Hear Me Out is built around the idea that phone calls should not be limited to people who can hear and speak.

Communication is more than just producing and receiving spoken words. Everyone deserves the opportunity to participate in conversations independently.

We aim to transform conventional calling into a more accessible experience by bringing together voice technology, real-time transcription, and inclusive design.

**Hear Me Out — Every voice deserves to be heard.**
