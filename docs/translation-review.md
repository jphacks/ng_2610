# Translation and pictogram review table

All three packages were written for this build and **none has been reviewed by a native speaker**. Before public use, a reviewer for each language must check the safety-critical strings below. Placeholders and keys are validated automatically (`npm run languages:validate`); meaning is not.

| Key | ja | en | ko | Reviewed by / date |
| --- | --- | --- | --- | --- |
| guide.protect.title | 地震です。頭を守ってください。 | Earthquake. Protect your head. | 지진입니다. 머리를 보호하세요. | |
| guide.shakingQuestion | 揺れがおさまりましたか | Has the shaking stopped? | 흔들림이 멈췄나요? | |
| guide.fire.body | 揺れがおさまり、安全にできる場合だけ。危険な場所へ戻らない。 | Only once shaking stops and it's safe. Don't go back into danger. | 흔들림이 멈추고 안전할 때만. 위험한 곳으로 돌아가지 마세요. | |
| guide.unsafeButton | 安全でないと感じたら | If you feel unsafe | 안전하지 않다고 느끼면 | |
| guide.tsunami.title | 津波がきます。高台へ。 | Tsunami coming. Go to high ground. | 쓰나미가 옵니다. 높은 곳으로. | |
| guide.tsunami.drillBody | 実際の津波の発生を示すものではありません。 | It does not mean a real tsunami is happening. | 실제 쓰나미 발생을 뜻하지 않습니다. | |
| guide.tsunami.grade.* | 大津波警報 / 津波警報 / 津波注意報 | Major tsunami warning / Tsunami warning / Tsunami advisory | 대형 쓰나미 경보 / 쓰나미 경보 / 쓰나미 주의보 | |
| noCandidates.cardBody | 施設が見つからなくても、避難が不要という意味ではありません… | No site found doesn't mean you don't need to evacuate… | 시설을 찾지 못해도 대피가 필요 없다는 뜻은 아닙니다… | |
| scale.45–60 | 5弱 5強 6弱 6強 | 5- 5+ 6- 6+ | 5약 5강 6약 6강 | |
| notification.*.body | (see packages) | | | |

Pictograms (`assets/pictograms/*.svg`, from Figma "Five action pictograms"): protect-head, check-surroundings, check-fire, secure-exit and tsunami-evacuate. Figma notes that their meaning must be validated with users before public release.
